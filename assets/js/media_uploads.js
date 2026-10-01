const csrfToken = () => document.querySelector("meta[name='csrf-token']").content

const requestJSON = async (url, body) => {
  const response = await fetch(url, {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
    body: JSON.stringify(body),
  })
  const payload = await response.json().catch(() => ({}))

  if (!response.ok) throw new Error(payload.error || "The upload failed.")
  return payload
}

const sha256 = async file => {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("")
}

const uploadObject = async (root, file, kind) => {
  const instructions = await requestJSON(root.dataset.prepareUrl, {
    kind,
    mime_type: file.type,
    byte_size: file.size,
    sha256: await sha256(file),
  })

  const upload = await fetch(instructions.url, {
    method: "PUT",
    headers: instructions.headers,
    body: file,
  })

  if (!upload.ok) throw new Error("Object storage rejected the upload.")
  return requestJSON(root.dataset.completeUrl, instructions.completion)
}

const initializeUploader = root => {
  if (root.dataset.initialized) return
  root.dataset.initialized = "true"

  const list = root.querySelector("[data-media-list]")
  const status = root.querySelector("[data-upload-status]")
  const audioInput = root.querySelector("[data-audio-input]")
  const imageInput = root.querySelector("[data-image-input]")
  const recordButton = root.querySelector("[data-record-audio]")
  const submitButton = root.closest("form")?.querySelector("button[type='submit']") ||
    document.querySelector("#approve-submission")
  const submitWasDisabled = submitButton?.disabled
  const maxImages = root.dataset.maxImages ? Number(root.dataset.maxImages) : Infinity
  let activeUploads = 0

  const items = kind => [...list.querySelectorAll(`[data-media-item][data-kind='${kind}']`)]
  const setStatus = message => status.textContent = message
  const setBusy = busy => {
    activeUploads += busy ? 1 : -1
    const uploading = activeUploads > 0
    if (audioInput) audioInput.disabled = uploading
    if (imageInput) imageInput.disabled = uploading
    if (recordButton) recordButton.disabled = uploading
    if (submitButton) submitButton.disabled = uploading || submitWasDisabled
  }

  const bindRemove = button => button.addEventListener("click", () => button.closest("[data-media-item]").remove())
  root.querySelectorAll("[data-remove-upload]").forEach(bindRemove)

  const addContributorItem = (item, file) => {
    const row = document.createElement("li")
    row.id = `contribution-media-${item.public_id}`
    row.className = "media-card"
    row.dataset.mediaItem = ""
    row.dataset.kind = item.kind

    const preview = document.createElement(item.kind === "audio" ? "audio" : "img")
    preview.src = URL.createObjectURL(file)
    if (item.kind === "audio") {
      preview.controls = true
    } else {
      preview.alt = "Selected cultural context"
    }

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = "contribution[media_public_ids][]"
    hidden.value = item.public_id

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "link-button"
    remove.textContent = "Remove"
    remove.dataset.removeUpload = ""
    bindRemove(remove)

    row.append(preview, hidden, remove)
    list.append(row)
  }

  const store = async (file, kind) => {
    setBusy(true)
    setStatus(`Uploading ${kind}…`)

    try {
      const item = await uploadObject(root, file, kind)

      if (root.dataset.attachUrl) {
        await requestJSON(root.dataset.attachUrl, {
          media_public_id: item.public_id,
          action: kind === "audio" ? "replace" : "attach",
        })
      } else if (!root.dataset.reloadAfterUpload) {
        addContributorItem(item, file)
      }

      setStatus(`${kind === "audio" ? "Audio" : "Image"} uploaded.`)
      return true
    } catch (error) {
      setStatus(error.message)
      return false
    } finally {
      setBusy(false)
    }
  }

  audioInput?.addEventListener("change", async event => {
    const file = event.target.files[0]
    event.target.value = ""
    if (!file) return

    if (!root.dataset.attachUrl && items("audio").length > 0) {
      setStatus("Remove the existing pronunciation before adding another.")
      return
    }

    if (await store(file, "audio") && (root.dataset.attachUrl || root.dataset.reloadAfterUpload)) {
      window.location.reload()
    }
  })

  imageInput?.addEventListener("change", async event => {
    const selectedFiles = [...event.target.files]
    if (selectedFiles.length === 0) return

    const available = maxImages - items("image").length
    const files = selectedFiles.slice(0, Math.max(available, 0))
    event.target.value = ""

    if (files.length === 0) {
      setStatus(`You can attach at most ${maxImages} images.`)
      return
    }

    let attached = false
    for (const file of files) attached = await store(file, "image") || attached
    if (attached && (root.dataset.attachUrl || root.dataset.reloadAfterUpload)) {
      window.location.reload()
    }
  })

  if (!recordButton) return

  if (!window.MediaRecorder || !navigator.mediaDevices?.getUserMedia) {
    recordButton.disabled = true
    recordButton.title = "Audio recording is not supported in this browser."
    return
  }

  const defaultRecordLabel = recordButton.textContent.trim()
  let recorder
  let stream
  let chunks = []

  recordButton.addEventListener("click", async () => {
    if (recorder?.state === "recording") {
      recorder.stop()
      recordButton.disabled = true
      recordButton.textContent = "Uploading…"
      return
    }

    if (!root.dataset.attachUrl && items("audio").length > 0) {
      setStatus("Remove the existing pronunciation before recording another.")
      return
    }

    try {
      if (submitButton) submitButton.disabled = true
      stream = await navigator.mediaDevices.getUserMedia({audio: true})
      chunks = []
      recorder = new MediaRecorder(stream)
      recorder.addEventListener("dataavailable", event => {
        if (event.data.size > 0) chunks.push(event.data)
      })
      recorder.addEventListener("stop", async () => {
        stream.getTracks().forEach(track => track.stop())
        const recording = new Blob(chunks, {type: recorder.mimeType})
        const stored = await store(recording, "audio")
        recordButton.textContent = defaultRecordLabel
        recordButton.disabled = false
        if (stored && (root.dataset.attachUrl || root.dataset.reloadAfterUpload)) {
          window.location.reload()
        }
      })
      recorder.start()
      recordButton.textContent = "Stop and upload"
      setStatus("Recording pronunciation…")
    } catch (_error) {
      if (submitButton) submitButton.disabled = submitWasDisabled
      setStatus("Microphone access was not available.")
    }
  })
}

export const initializeMediaUploads = () => {
  document.querySelectorAll("[data-media-uploader]").forEach(initializeUploader)
}
