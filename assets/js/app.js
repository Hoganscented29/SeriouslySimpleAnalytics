// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/web_analytics"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
// Click to hold a highlight until the pointer leaves.
//
// No markup to change: the elements that should respond to this are exactly
// the ones that already declare a hover style, and that is readable off the
// class list. A table row counts too — daisyUI puts its hover on the row
// rather than in a utility class.
const holdable = (el) =>
  el.tagName === "TR" || /(^|\s)hover:/.test(el.getAttribute("class") || "")

document.addEventListener("click", (event) => {
  let el = event.target instanceof Element ? event.target : null

  while (el && el !== document.body && !holdable(el)) {
    el = el.parentElement
  }

  if (!el || el === document.body) { return }

  el.classList.add("wa-held")
  // `once`, so a row clicked twice does not accumulate listeners, and the
  // class is gone the moment the pointer leaves rather than on the next click.
  el.addEventListener("mouseleave", () => el.classList.remove("wa-held"), {once: true})
})

// The server was redeployed while this tab was open. Tell the tag first, so
// the reload does not book a second pageview against the visit or throw away
// the dwell time already measured, then reload.
window.addEventListener("phx:wa:reload", () => {
  try {
    if (window.__webAnalytics && window.__webAnalytics.prepareReload) {
      window.__webAnalytics.prepareReload()
    }
  } catch (e) {
    // A tag that cannot be told is not a reason to keep serving a stale build.
  }

  window.location.reload()
})

liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

