import test from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {webcrypto} from "node:crypto"
import vm from "node:vm"

// Only the browser primitives touched by this enhancement are supplied. The
// tests exercise the real uploader without a microphone or object-storage server.
class Element {
  constructor(tag = "div") {
    this.tag = tag
    this.dataset = {}
    this.children = []
    this.handlers = new Map()
    this.attributes = {}
    this.textContent = ""
    this.value = ""
    this.src = ""
  }
  append(...children) { children.forEach(child => { child.parent = this; this.children.push(child) }) }
  after(child) { this.parent.append(child) }
  addEventListener(name, callback) { this.handlers.set(name, callback) }
  async emit(name, event = {}) { return this.handlers.get(name)?.({target: this, ...event}) }
  setAttribute(name, value) { this.attributes[name] = value }
  removeAttribute(name) { delete this.attributes[name]; if (name === "src") this.src = "" }
  focus() { this.focused = true }
  closest(selector) { return selector === "form" ? this.form : this.parent }
  querySelector(selector) { return this.selectors?.[selector] || null }
  querySelectorAll(selector) {
    if (selector.includes("data-media-item")) return this.children.filter(item => item.dataset.kind === selector.match(/data-kind='([^']+)'/)[1])
    return []
  }
  remove() { this.parent.children = this.parent.children.filter(child => child !== this) }
}

function uploader({locale = "en", uploadFails = false, supported = true} = {}) {
  const root = new Element()
  root.id = "test-media"
  root.dataset = {prepareUrl: "/prepare", completeUrl: "/complete", maxImages: "5"}
  const form = new Element("form")
  const submit = new Element("button")
  const list = new Element("ul")
  const status = new Element("p")
  const audioInput = new Element("input")
  const record = new Element("button")
  record.textContent = "Record pronunciation"
  const permission = new Element("input")
  permission.checked = false
  const place = new Element("input")
  place.value = "Kalpa"
  root.form = form
  form.selectors = {"button[type='submit']": submit}
  root.selectors = {
    "[data-media-list]": list, "[data-upload-status]": status,
    "[data-audio-input]": audioInput, "[data-record-audio]": record,
    "[data-media-permission]": permission, "[data-media-place]": place,
  }
  root.append(list, status, audioInput, record, permission, place)
  let requests = [], microphoneRequests = 0
  class Recorder extends Element {
    constructor() { super(); this.mimeType = "audio/webm" }
    start() { this.state = "recording" }
    stop() {
      this.state = "inactive"
      this.emit("dataavailable", {data: new Blob(["recording"], {type: this.mimeType})})
      this.emit("stop")
    }
  }
  class XHR {
    upload = {}
    open() {}
    setRequestHeader() {}
    send() {
      this.status = uploadFails ? 503 : 200
      this.upload.onprogress?.({lengthComputable: true, loaded: 10, total: 10})
      this.onload()
    }
  }
  const document = {
    documentElement: {lang: locale},
    querySelector: () => ({content: "test-csrf"}),
    querySelectorAll: () => [root],
    createElement: tag => new Element(tag),
  }
  const context = vm.createContext({
    document, Blob, crypto: webcrypto, XMLHttpRequest: XHR, MediaRecorder: Recorder,
    URL: {createObjectURL: () => "blob:test", revokeObjectURL() {}},
    navigator: {mediaDevices: {async getUserMedia() { microphoneRequests++; return {getTracks: () => [{stop() {}}]} }}},
    window: {MediaRecorder: supported ? Recorder : undefined, addEventListener() {}},
    setInterval: () => 1, clearInterval() {},
    async fetch(url, options) {
      requests.push({url, body: JSON.parse(options.body)})
      return {ok: true, async json() { return url === "/prepare"
        ? {url: "/object", headers: {}, completion: {kind: "audio"}}
        : {kind: "audio", public_id: "uploaded-recording"} }}
    },
  })
  vm.runInContext(readFileSync(new URL("../../assets/js/media_uploads.js", import.meta.url), "utf8")
    .replace("export const initializeMediaUploads", "const initializeMediaUploads") + "\ninitializeMediaUploads()", context)
  return {root, list, status, audioInput, record, permission, place, submit, requests,
    microphoneRequests: () => microphoneRequests, allowUploads: () => { uploadFails = false },
    button: label => root.children.find(child => child.textContent === label),
  }
}

test("permission is checked before microphone access", async () => {
  const ui = uploader({locale: "hi"})
  await ui.record.emit("click")
  assert.equal(ui.microphoneRequests(), 0)
  assert.equal(ui.permission.focused, true)
  assert.match(ui.status.textContent, /अनुमति/)
})

test("a recording can be heard before any upload and carries village context", async () => {
  const ui = uploader()
  ui.permission.checked = true
  await ui.record.emit("click")
  assert.equal(ui.submit.disabled, true)
  await ui.record.emit("click")
  assert.equal(ui.requests.length, 0)
  assert.equal(ui.submit.disabled, true)
  const preview = ui.root.children.find(child => child.children.some(item => item.tag === "audio"))
  assert.equal(preview.children[0].src, "blob:test")
  await preview.children.find(child => child.textContent === "Upload this recording").emit("click")
  assert.equal(ui.requests[0].body.place_label, "Kalpa")
  assert.equal(ui.list.children.length, 1)
  assert.equal(ui.submit.disabled, false)
})

test("an interrupted upload retains the file for retry and prevents an incomplete send", async () => {
  const ui = uploader({uploadFails: true})
  ui.permission.checked = true
  ui.audioInput.files = [new Blob(["audio"], {type: "audio/webm"})]
  await ui.audioInput.emit("change")
  assert.equal(ui.submit.disabled, true)
  assert.equal(ui.list.children.length, 0)
  assert.equal(ui.place.value, "Kalpa")
  assert.match(ui.status.textContent, /remain on this page/)
  const retry = ui.button("Retry upload")
  assert.equal(retry.hidden, false)
  ui.allowUploads()
  await retry.emit("click")
  assert.equal(ui.list.children.length, 1)
  assert.equal(ui.submit.disabled, false)
})

test("failed uploads can be discarded so another file can be selected", async () => {
  const ui = uploader({uploadFails: true})
  ui.permission.checked = true
  ui.audioInput.files = [new Blob(["audio"], {type: "audio/webm"})]
  await ui.audioInput.emit("change")
  await ui.button("Discard failed uploads and choose again").emit("click")
  assert.equal(ui.submit.disabled, false)
  assert.equal(ui.place.value, "Kalpa")
  assert.equal(ui.button("Retry upload").hidden, true)
})

test("unsupported recording has a visible Hindi explanation and usable file upload", () => {
  const ui = uploader({locale: "hi", supported: false})
  assert.equal(ui.record.disabled, true)
  assert.equal(ui.audioInput.disabled, false)
  assert.match(ui.status.textContent, /ऑडियो फ़ाइल अपलोड/)
})
