const text = (en, hi) => document.documentElement.lang === "hi" ? hi : en
const csrfToken = () => document.querySelector("meta[name='csrf-token']").content

const requestJSON = async (url, body) => {
  const response = await fetch(url, {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
    body: JSON.stringify(body),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(payload.error)
  return payload
}

const sha256 = async file => {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("")
}

const uploadObject = async (root, file, kind, onProgress) => {
  const instructions = await requestJSON(root.dataset.prepareUrl, {
    kind, mime_type: file.type, byte_size: file.size, sha256: await sha256(file),
    place_label: root.querySelector("[data-media-place]")?.value,
    attribution_text: root.querySelector("[data-media-attribution]")?.value,
  })
  await new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open("PUT", instructions.url)
    Object.entries(instructions.headers).forEach(([key, value]) => xhr.setRequestHeader(key, value))
    xhr.upload.onprogress = event => {
      if (event.lengthComputable) onProgress(Math.round(event.loaded * 100 / event.total))
    }
    xhr.onload = () => xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new Error("upload"))
    xhr.onerror = xhr.onabort = () => reject(new Error("upload"))
    xhr.send(file)
  })
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
  const permission = root.querySelector("[data-media-permission]")
  const submitButton = root.closest("form")?.querySelector("button[type='submit']") || document.querySelector("#approve-submission")
  const submitWasDisabled = submitButton?.disabled && !submitButton?.dataset.mediaRequired
  const maxImages = root.dataset.maxImages ? Number(root.dataset.maxImages) : Infinity
  let busy = false
  let recording = false
  let recordedFile = null
  let failed = []
  const items = kind => [...list.querySelectorAll(`[data-media-item][data-kind='${kind}']`)]
  const setStatus = message => { status.textContent = message }

  const progress = document.createElement("progress")
  progress.id = `${root.id}-progress`
  progress.max = 100
  progress.hidden = true
  progress.setAttribute("aria-hidden", "true")
  const progressText = document.createElement("p")
  progressText.id = `${root.id}-progress-text`
  progressText.hidden = true
  progressText.className = "help-text"
  const retry = document.createElement("button")
  retry.type = "button"
  retry.id = `${root.id}-retry`
  retry.className = "secondary-button"
  retry.textContent = text("Retry upload", "फिर से अपलोड करें")
  retry.hidden = true
  const discardFailed = document.createElement("button")
  discardFailed.type = "button"
  discardFailed.id = `${root.id}-discard-failed`
  discardFailed.className = "link-button"
  discardFailed.textContent = text("Discard failed uploads and choose again", "रुकी हुई फ़ाइलें हटाएँ और फिर चुनें")
  discardFailed.hidden = true
  root.append(progress, progressText, retry, discardFailed)

  const setBusy = value => {
    busy = value
    root.setAttribute("aria-busy", String(value))
    if (audioInput) audioInput.disabled = value || recording || !!recordedFile
    if (imageInput) imageInput.disabled = value || recording || !!recordedFile
    if (recordButton) recordButton.disabled = value
    if (submitButton) submitButton.disabled = Boolean(value || recording || recordedFile || submitWasDisabled || failed.length > 0 || (submitButton.dataset.mediaRequired && list.children.length === 0))
    retry.disabled = discardFailed.disabled = value
    root.querySelectorAll("[data-remove-upload]").forEach(button => { button.disabled = value || recording })
    progress.hidden = progressText.hidden = !value
  }
  const permitted = () => {
    if (!permission || permission.checked) return true
    setStatus(text("Confirm public-use permission before recording or uploading.", "रिकॉर्ड या अपलोड करने से पहले सार्वजनिक उपयोग की अनुमति की पुष्टि करें।"))
    permission.focus()
    return false
  }
  setBusy(false)

  const bindRemove = button => button.addEventListener("click", () => {
    const row = button.closest("[data-media-item]")
    const preview = row.querySelector("audio, img")
    if (preview?.src.startsWith("blob:")) URL.revokeObjectURL(preview.src)
    row.remove()
    setBusy(false)
    setStatus(text("Media removed from this suggestion.", "इस सुझाव से रिकॉर्डिंग या चित्र हटा दिया गया है।"))
  })
  root.querySelectorAll("[data-remove-upload]").forEach(bindRemove)

  const addContributorItem = (item, file) => {
    const row = document.createElement("li")
    row.id = `contribution-media-${item.public_id}`
    row.className = "media-card"
    row.dataset.mediaItem = ""
    row.dataset.kind = item.kind
    const preview = document.createElement(item.kind === "audio" ? "audio" : "img")
    preview.id = `${row.id}-preview`
    preview.src = URL.createObjectURL(file)
    if (item.kind === "audio") {
      preview.controls = true
      preview.preload = "none"
      preview.setAttribute("aria-label", text("Your pronunciation recording", "आपकी उच्चारण रिकॉर्डिंग"))
    } else {
      preview.alt = text("Selected cultural context image", "चुना गया सांस्कृतिक संदर्भ का चित्र")
    }
    const hidden = document.createElement("input")
    hidden.id = `${row.id}-id`
    hidden.type = "hidden"
    hidden.name = "contribution[media_public_ids][]"
    hidden.value = item.public_id
    const remove = document.createElement("button")
    remove.id = `${row.id}-remove`
    remove.type = "button"
    remove.className = "link-button"
    remove.textContent = text("Remove", "हटाएँ")
    remove.dataset.removeUpload = ""
    bindRemove(remove)
    row.append(preview, hidden, remove)
    list.append(row)
  }

  const store = async (file, kind) => {
    setBusy(true)
    progress.value = 0
    progressText.textContent = text("Uploading: 0%", "अपलोड हो रहा है: 0%")
    setStatus(text("Uploading. Keep this page open.", "अपलोड हो रहा है। इस पेज को खुला रखें।"))
    try {
      const item = await uploadObject(root, file, kind, percent => {
        progress.value = percent
        progressText.textContent = text(`Uploading: ${percent}%`, `अपलोड हो रहा है: ${percent}%`)
      })
      if (root.dataset.attachUrl) {
        await requestJSON(root.dataset.attachUrl, {media_public_id: item.public_id, action: kind === "audio" ? "replace" : "attach"})
      } else if (!root.dataset.reloadAfterUpload) {
        addContributorItem(item, file)
      }
      setStatus(failed.length > 0
        ? text("Some uploads are still waiting. Retry or discard the remaining files.", "कुछ फ़ाइलें अभी बाकी हैं। उन्हें फिर अपलोड करें या हटाएँ।")
        : text("Upload complete. Check your suggestion before sending it for review.", "अपलोड पूरा हुआ। समीक्षा के लिए भेजने से पहले अपना सुझाव जाँच लें।"))
      return true
    } catch (_error) {
      failed.push({file, kind})
      retry.hidden = discardFailed.hidden = false
      setStatus(text("Upload interrupted or unavailable. Your file and entered text remain on this page. Retry the upload.", "अपलोड रुक गया या सेवा उपलब्ध नहीं है। आपकी फ़ाइल और लिखी जानकारी इस पेज पर हैं। फिर से अपलोड करें।"))
      return false
    } finally {
      setBusy(false)
    }
  }
  discardFailed.addEventListener("click", () => {
    failed = []
    retry.hidden = discardFailed.hidden = true
    setBusy(false)
    setStatus(text("Failed files discarded. Your entered text is still here. Choose another file.", "रुकी हुई फ़ाइलें हटा दी गई हैं। आपकी लिखी जानकारी यहीं है। दूसरी फ़ाइल चुनें।"))
  })
  const reloadIfNeeded = stored => {
    if (stored && failed.length === 0 && (root.dataset.attachUrl || root.dataset.reloadAfterUpload)) window.location.reload()
  }
  retry.addEventListener("click", async () => {
    if (busy || !permitted()) return
    const pending = failed
    failed = []
    retry.hidden = discardFailed.hidden = true
    let stored = false
    for (const {file, kind} of pending) stored = await store(file, kind) || stored
    reloadIfNeeded(stored)
  })

  audioInput?.addEventListener("change", async event => {
    const file = event.target.files[0]
    event.target.value = ""
    if (!file || busy || !permitted()) return
    if (!root.dataset.attachUrl && (items("audio").length > 0 || failed.some(item => item.kind === "audio"))) {
      setStatus(text("Remove or retry the existing pronunciation first.", "पहले मौजूदा उच्चारण हटाएँ या उसका अपलोड फिर से करें।"))
      return
    }
    reloadIfNeeded(await store(file, "audio"))
  })
  imageInput?.addEventListener("change", async event => {
    const files = [...event.target.files]
    event.target.value = ""
    if (files.length === 0 || busy || !permitted()) return
    if (files.length + items("image").length + failed.filter(item => item.kind === "image").length > maxImages) {
      setStatus(text(`Choose at most ${maxImages} images in total. No files were uploaded.`, `कुल ${maxImages} तक चित्र चुनें। कोई फ़ाइल अपलोड नहीं हुई है।`))
      return
    }
    let stored = false
    for (const file of files) stored = await store(file, "image") || stored
    reloadIfNeeded(stored)
  })

  if (!recordButton) return
  recordButton.hidden = false
  if (!window.MediaRecorder || !navigator.mediaDevices?.getUserMedia) {
    recordButton.disabled = true
    setStatus(text("Recording is unavailable in this browser. Upload an audio file instead.", "इस ब्राउज़र में रिकॉर्डिंग उपलब्ध नहीं है। ऑडियो फ़ाइल अपलोड करें।"))
    return
  }
  const defaultRecordLabel = recordButton.textContent.trim()
  const recordingPreview = document.createElement("div")
  recordingPreview.id = `${root.id}-recording-preview`
  recordingPreview.className = "media-controls"
  recordingPreview.hidden = true
  const preview = document.createElement("audio")
  preview.controls = true
  preview.preload = "none"
  preview.setAttribute("aria-label", text("Listen to your recording before uploading", "अपलोड करने से पहले अपनी रिकॉर्डिंग सुनें"))
  preview.id = `${root.id}-recording-audio`
  const duration = document.createElement("p")
  duration.id = `${root.id}-recording-time`
  duration.className = "help-text"
  const useRecording = document.createElement("button")
  useRecording.id = `${root.id}-upload-recording`
  useRecording.type = "button"
  useRecording.className = "secondary-button"
  useRecording.textContent = text("Upload this recording", "यह रिकॉर्डिंग अपलोड करें")
  const discard = document.createElement("button")
  discard.id = `${root.id}-discard-recording`
  discard.type = "button"
  discard.className = "link-button"
  discard.textContent = text("Discard and record again", "हटाएँ और फिर से रिकॉर्ड करें")
  recordingPreview.append(preview, duration, useRecording, discard)
  recordButton.after(recordingPreview)
  let recorder, stream, chunks, timer, startedAt
  const clearPreview = () => {
    if (preview.src.startsWith("blob:")) URL.revokeObjectURL(preview.src)
    preview.removeAttribute("src")
    recordedFile = null
    recordingPreview.hidden = true
    recordButton.hidden = false
    setBusy(false)
  }
  discard.addEventListener("click", () => { clearPreview(); recordButton.focus() })
  useRecording.addEventListener("click", async () => {
    if (!recordedFile || busy || !permitted()) return
    useRecording.disabled = discard.disabled = true
    const stored = await store(recordedFile, "audio")
    clearPreview()
    useRecording.disabled = discard.disabled = false
    reloadIfNeeded(stored)
  })
  recordButton.addEventListener("click", async () => {
    if (recorder?.state === "recording") { recorder.stop(); return }
    if (busy || !permitted()) return
    if (!root.dataset.attachUrl && (items("audio").length > 0 || failed.some(item => item.kind === "audio"))) {
      setStatus(text("Remove or retry the existing pronunciation first.", "पहले मौजूदा उच्चारण हटाएँ या उसका अपलोड फिर से करें।"))
      return
    }
    recording = true
    setBusy(true)
    try {
      stream = await navigator.mediaDevices.getUserMedia({audio: true})
      chunks = []
      recorder = new MediaRecorder(stream)
      recorder.addEventListener("dataavailable", event => { if (event.data.size > 0) chunks.push(event.data) })
      recorder.addEventListener("stop", () => {
        clearInterval(timer)
        stream.getTracks().forEach(track => track.stop())
        recordedFile = new Blob(chunks, {type: recorder.mimeType})
        preview.src = URL.createObjectURL(recordedFile)
        recording = false
        preview.hidden = useRecording.hidden = discard.hidden = false
        setBusy(false)
        recordButton.textContent = defaultRecordLabel
        recordButton.hidden = true
        setStatus(text("Recording ready. Listen before uploading.", "रिकॉर्डिंग तैयार है। अपलोड करने से पहले सुनें।"))
      })
      startedAt = Date.now()
      const updateTime = () => { duration.textContent = text(`Recording time: ${Math.floor((Date.now() - startedAt) / 1000)} seconds`, `रिकॉर्डिंग का समय: ${Math.floor((Date.now() - startedAt) / 1000)} सेकंड`) }
      updateTime()
      timer = setInterval(updateTime, 1000)
      recordingPreview.hidden = false
      preview.hidden = useRecording.hidden = discard.hidden = true
      recording = true
      setBusy(false)
      recordButton.textContent = text("Stop recording", "रिकॉर्डिंग रोकें")
      recorder.start()
      setStatus(text("Recording pronunciation. Press Stop when finished.", "उच्चारण रिकॉर्ड हो रहा है। पूरा होने पर रिकॉर्डिंग रोकें।"))
    } catch (_error) {
      clearInterval(timer)
      stream?.getTracks().forEach(track => track.stop())
      recording = false
      setBusy(false)
      recordButton.textContent = defaultRecordLabel
      recordingPreview.hidden = true
      setStatus(text("Microphone access was unavailable. Allow access and try again, or upload a file.", "माइक्रोफ़ोन उपलब्ध नहीं है। अनुमति देकर फिर कोशिश करें, या फ़ाइल अपलोड करें।"))
    }
  })
  window.addEventListener("pagehide", () => {
    clearInterval(timer)
    stream?.getTracks().forEach(track => track.stop())
  })
}

export const initializeMediaUploads = () => {
  document.querySelectorAll("[data-media-uploader]").forEach(initializeUploader)
}
