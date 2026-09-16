import { Controller } from "@hotwired/stimulus"

// The native bridge from JavaScript.
//
// In "ask" mode it asks the desktop shell about the window this page is in and
// reports the answer to the server. The server replies over the "native"
// stream, and the element it sends connects this controller in "receipt" mode,
// which reports that the reply arrived.
//
// desktop-rails.js is injected by the shell once the page has loaded, so it may
// not be there yet when this connects; in a plain browser it never is.
export default class extends Controller {
  static targets = ["status"]
  static values = { mode: String, reportUrl: String }

  async connect() {
    if (this.modeValue === "receipt") {
      await this.report("stream", true, { received: this.element.textContent.trim() })
      return
    }

    const bridge = await this.waitFor(() => window.DesktopRails, 10000)
    if (!bridge) {
      this.statusTarget.textContent = "Not running in the desktop shell."
      return
    }

    // Subscribed before asking, or the server's reply could be broadcast
    // before this page is listening for it.
    await this.waitFor(() => document.getElementById("native_stream")?.streamSource?.readyState === EventSource.OPEN, 10000)

    const state = await bridge.window.state()
    const ok = state?.status === "ok"
    this.statusTarget.textContent = ok
      ? `The shell says this is the "${state.label}" window, ${Math.round(state.width)}×${Math.round(state.height)}.`
      : "The shell did not answer."
    await this.report("javascript", ok, { state, bridge: typeof window.__TAURI_INTERNALS__?.invoke })
  }

  async report(kind, ok, detail) {
    await fetch(this.reportUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      },
      body: JSON.stringify({ kind, ok, detail })
    })
  }

  async waitFor(check, timeout) {
    for (let waited = 0; waited < timeout; waited += 100) {
      const value = check()
      if (value) return value
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    return null
  }
}
