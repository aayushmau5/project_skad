export function initializeLiveSearch() {
  const form = document.querySelector("[data-live-search]")
  if (!form) return

  const queryInput = form.querySelector("#q")
  const output = document.querySelector("#search-output")
  const status = document.querySelector("#search-status")
  const recentWords = document.querySelector("#recent-words")
  let timer
  let controller
  let version = 0

  const stopPending = () => {
    clearTimeout(timer)
    controller?.abort()
    version++
  }

  const syncAddress = (query, language) => {
    const url = new URL(window.location.href)
    if (query) url.searchParams.set("q", query)
    else url.searchParams.delete("q")
    if (language) url.searchParams.set("language", language)
    else url.searchParams.delete("language")
    window.history.replaceState(window.history.state, "", url)

    document.querySelectorAll("#interface-language a").forEach(link => {
      const target = new URL(link.href)
      if (query) target.searchParams.set("q", query)
      else target.searchParams.delete("q")
      if (language) target.searchParams.set("language", language)
      else target.searchParams.delete("language")
      link.href = target.href
    })
  }

  const update = () => {
    stopPending()
    output.replaceChildren()
    status.hidden = true
    status.dataset.state = ""
    output.setAttribute("aria-busy", "false")

    const query = queryInput.value.trim()
    if (recentWords) recentWords.hidden = query !== ""
    const language = form.querySelector('input[name="language"]:checked')?.value || ""
    syncAddress(query, language)
    if (!query) return

    const current = version
    timer = setTimeout(async () => {
      controller = new AbortController()
      output.setAttribute("aria-busy", "true")
      status.textContent = form.dataset.searching
      status.hidden = false

      const url = new URL(form.dataset.resultsUrl, window.location.origin)
      url.searchParams.set("q", query)
      if (language) url.searchParams.set("language", language)

      try {
        const response = await fetch(url, {
          signal: controller.signal,
          headers: {Accept: "text/html"},
          cache: "no-store",
        })
        if (!response.ok) throw new Error("Search request failed")
        const html = await response.text()
        if (current !== version) return

        output.innerHTML = html
        const results = output.querySelector("#search-results")
        if (!results) throw new Error("Search response missing results")
        status.textContent = results.dataset.resultCount === "0"
          ? form.dataset.noResults
          : form.dataset.resultsReady
        status.dataset.state = results.dataset.resultCount === "0" ? "" : "ready"
      } catch (error) {
        if (current !== version || error.name === "AbortError") return
        output.replaceChildren()
        status.textContent = form.dataset.searchError
      } finally {
        if (current === version) output.setAttribute("aria-busy", "false")
      }
    }, 300)
  }

  queryInput.addEventListener("input", update)
  form.addEventListener("change", event => {
    if (event.target.name === "language") update()
  })
  form.addEventListener("submit", stopPending)
  window.addEventListener("pagehide", stopPending)
}
