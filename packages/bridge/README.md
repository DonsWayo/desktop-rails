# desktop-rails-bridge

Typed ESM imports for the [Desktop Rails](https://github.com/DonsWayo/desktop-rails) JavaScript bridge API.

## Installation

```bash
npm install desktop-rails-bridge
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

The `desktop-rails.js` IIFE is automatically injected by the Tauri shell into every page. This package provides typed ESM exports that reference the same `window.DesktopRails` globals — no bundling or duplication required.

## License

MIT
