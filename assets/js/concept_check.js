export function initializeConceptCheck() {
  const form = document.querySelector("[data-concept-check]")
  if (!form) return

  const input = form.querySelector("#concept_editorial_label")
  const output = form.querySelector("#concept-check-output")
  let timer
  let controller
  let version = 0

  const stopPending = () => {
    clearTimeout(timer)
    controller?.abort()
    version++
    output.setAttribute("aria-busy", "false")
  }

  const check = async () => {
    if (!input.value.trim()) return
    const current = version
    controller = new AbortController()
    output.hidden = false
    output.textContent = form.dataset.searching
    output.setAttribute("aria-busy", "true")
    const url = new URL(form.dataset.matchesUrl, window.location.origin)
    url.searchParams.set("label", input.value.trim())

    try {
      const response = await fetch(url, {
        signal: controller.signal,
        headers: {Accept: "text/html"},
        cache: "no-store",
      })
      if (!response.ok) throw new Error("Concept check failed")
      const html = await response.text()
      if (current !== version) return
      const results = new DOMParser().parseFromString(html, "text/html").querySelector("#concept-match-results")
      if (!results) throw new Error("Concept check response missing results")
      output.replaceChildren(results)
    } catch (error) {
      if (current === version && error.name !== "AbortError") {
        output.textContent = form.dataset.searchError
      }
    } finally {
      if (current === version) output.setAttribute("aria-busy", "false")
    }
  }

  input.addEventListener("input", () => {
    stopPending()
    output.replaceChildren()
    output.hidden = true
    if (input.value.trim()) timer = setTimeout(check, 300)
  })
  form.querySelector("#check-concept").addEventListener("click", event => {
    event.preventDefault()
    stopPending()
    check()
  })
  form.addEventListener("submit", stopPending)
  window.addEventListener("pagehide", stopPending)
}
