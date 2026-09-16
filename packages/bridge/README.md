# desktop-rails-bridge

Typed ESM imports for the [desktop-rails](https://github.com/DonsWayo/desktop-rails) JavaScript bridge API.

## Installation

This package is not published to npm. You do not need it to use the bridge: the
shell injects `window.DesktopRails` into every page of your app. It only adds
module imports and TypeScript types over that global.

To use it, copy `index.js` and `index.d.ts` from
[`packages/bridge`](https://github.com/DonsWayo/desktop-rails/tree/main/packages/bridge)
into your app. With importmap-rails, that is `vendor/javascript/desktop-rails-bridge.js`
and a pin:

```ruby
# config/importmap.rb
pin "desktop-rails-bridge"
```

## Usage

```javascript
import { DesktopRails, BridgeComponent, stimulusBridge, isDesktopRails } from "desktop-rails-bridge"

// Check if running inside a Desktop Rails shell
if (isDesktopRails()) {
  const info = await DesktopRails.getWindowInfo()
  console.log(`Running on ${info.platform}`)
}
```

### With Stimulus

```javascript
import { Controller } from "@hotwired/stimulus"
import { stimulusBridge } from "desktop-rails-bridge"

export default class extends stimulusBridge(Controller, "notification") {
  connect() {
    super.connect()
    this.sendBridge("connect", { title: "My App" })
  }

  receiveBridge(message) {
    console.log("Native says:", message)
  }
}
```

## How it works

The shell injects `desktop-rails.js` into every page, in bundled and hosted mode alike. This package re-exports the `window.DesktopRails` globals it defines as ESM, so there is nothing to bundle and no second copy of the bridge.

## License

MIT
