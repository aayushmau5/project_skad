import test from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

function setup(fetchResponse = async () => ({ok: true, text: async () => '<section id="search-results" data-result-count="1"></section>'})) {
  const handlers = new Map()
  const query = {value: "", addEventListener: (name, fn) => handlers.set(`query:${name}`, fn)}
  const language = {value: "", name: "language"}
  const output = {
    html: "",
    attributes: {},
    set innerHTML(html) { this.html = html },
    get innerHTML() { return this.html },
    replaceChildren() { this.html = "" },
    setAttribute(name, value) { this.attributes[name] = value },
    querySelector(selector) {
      if (selector !== "#search-results" || !this.html.includes('id="search-results"')) return null
      return {dataset: {resultCount: this.html.match(/data-result-count="(\d+)"/)?.[1]}}
    },
  }
  const status = {hidden: true, textContent: "", dataset: {}}
  const form = {
    dataset: {
      resultsUrl: "/search/results", searching: "Searching…", resultsReady: "Results updated.",
      noResults: "No matches yet.", searchError: "Check your connection and press Search.",
    },
    querySelector: selector => ({"#q": query, 'input[name="language"]:checked': language})[selector],
    addEventListener: (name, fn) => handlers.set(`form:${name}`, fn),
  }
  const nodes = {
    "[data-live-search]": form, "#search-output": output,
    "#search-status": status,
  }
  const links = [
    {href: "http://localhost:4000/?ui_language=hi"},
    {href: "http://localhost:4000/?ui_language=en"},
  ]
  const location = {href: "http://localhost:4000/?ui_language=hi", origin: "http://localhost:4000"}
  const history = {state: null, replaceState(_state, _title, url) { location.href = url.href }}
  const timers = []
  const requests = []
  const context = vm.createContext({
    document: {querySelector: selector => nodes[selector], querySelectorAll: () => links},
    window: {location, history, addEventListener: (name, fn) => handlers.set(`window:${name}`, fn)},
    URL, AbortController,
    setTimeout(fn, delay) { const timer = {fn, delay, cancelled: false}; timers.push(timer); return timer },
    clearTimeout(timer) { if (timer) timer.cancelled = true },
    async fetch(url, options) { requests.push({url, options}); return fetchResponse(url, options) },
  })
  vm.runInContext(
    readFileSync(new URL("../../assets/js/live_search.js", import.meta.url), "utf8")
      .replace("export function initializeLiveSearch", "function initializeLiveSearch") + "\ninitializeLiveSearch()",
    context,
  )

  return {
    query, language, output, status, requests, timers, links, location,
    emit: (target, event, detail = {}) => handlers.get(`${target}:${event}`)(detail),
    runTimer: async index => timers[index].cancelled ? undefined : timers[index].fn(),
  }
}

test("debounces typing and sends the selected archive language", async () => {
  const ui = setup()
  ui.language.value = "hindi"
  ui.query.value = "wat"
  ui.emit("query", "input")
  ui.query.value = "water"
  ui.emit("query", "input")

  assert.equal(ui.timers[0].cancelled, true)
  assert.equal(ui.timers[1].delay, 300)
  await ui.runTimer(1)

  assert.equal(ui.requests.length, 1)
  assert.equal(ui.requests[0].url.searchParams.get("q"), "water")
  assert.equal(ui.requests[0].url.searchParams.get("language"), "hindi")
  assert.equal(new URL(ui.location.href).searchParams.get("q"), "water")
  assert.equal(new URL(ui.links[1].href).searchParams.get("language"), "hindi")
  assert.equal(ui.status.textContent, "Results updated.")
  assert.equal(ui.status.dataset.state, "ready")
  assert.equal(ui.output.attributes["aria-busy"], "false")

  ui.language.value = ""
  ui.emit("form", "change", {target: ui.language})
  await ui.runTimer(2)
  assert.equal(ui.requests[1].url.searchParams.has("language"), false)
  assert.equal(new URL(ui.links[1].href).searchParams.has("language"), false)
})

test("a later language choice wins when an earlier response arrives last", async () => {
  let finishFirst
  const first = new Promise(resolve => { finishFirst = resolve })
  let calls = 0
  const ui = setup(async () => ++calls === 1 ? first : {
    ok: true, text: async () => '<section id="search-results" data-result-count="0">Hindi only</section>',
  })
  ui.query.value = "water"
  ui.emit("query", "input")
  const pending = ui.runTimer(0)

  ui.language.value = "hindi"
  ui.emit("form", "change", {target: ui.language})
  await ui.runTimer(1)
  finishFirst({ok: true, text: async () => '<section id="search-results" data-result-count="1">Old results</section>'})
  await pending

  assert.equal(ui.requests[0].options.signal.aborted, true)
  assert.equal(ui.requests[1].url.searchParams.get("language"), "hindi")
  assert.match(ui.output.innerHTML, /Hindi only/)
  assert.doesNotMatch(ui.output.innerHTML, /Old results/)
  assert.equal(ui.status.textContent, "No matches yet.")
  assert.equal(ui.status.dataset.state, "")
})

test("failure gives a recovery action, while clearing the query resets search", async () => {
  const ui = setup(async () => { throw new Error("offline") })
  ui.query.value = "water"
  ui.emit("query", "input")
  await ui.runTimer(0)
  assert.equal(ui.status.textContent, "Check your connection and press Search.")
  assert.equal(ui.status.hidden, false)
  assert.equal(ui.status.dataset.state, "")

  ui.query.value = ""
  ui.emit("query", "input")
  assert.equal(ui.status.hidden, true)
  assert.equal(ui.requests.length, 1)
  assert.equal(new URL(ui.location.href).searchParams.has("q"), false)
})
