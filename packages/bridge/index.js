/**
 * desktop-rails-bridge
 *
 * Typed ESM exports for the Desktop Rails JavaScript bridge.
 *
 * The desktop-rails.js IIFE is automatically injected by the Tauri shell
 * into every page via `on_page_load`. This package provides typed module
 * imports that reference the same globals — no bundling required.
 *
 * Usage:
 *   import { DesktopRails, BridgeComponent, stimulusBridge } from "desktop-rails-bridge"
 */

/** The main Desktop Rails API. */
export const DesktopRails = globalThis.DesktopRails;

/** The BridgeComponent base class for native communication. */
export const BridgeComponent = globalThis.DesktopRails?.BridgeComponent;

/** Factory to create Stimulus-compatible bridge controller mixins. */
export const stimulusBridge = globalThis.DesktopRails?.stimulusBridge;

/**
 * Check if the current environment is a Desktop Rails shell.
 * Returns false when running in a regular browser.
 */
export function isDesktopRails() {
  return globalThis.__DESKTOP_RAILS__?.isNative === true;
}
