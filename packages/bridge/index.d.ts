/**
 * desktop-rails-bridge — TypeScript definitions
 *
 * Re-exports all types from the desktop-rails.js bridge.
 */

export {
  DesktopRailsAPI,
  BridgeComponent,
  BridgeMessage,
  BridgeResponse,
  VisitResponse,
  WindowInfo,
  NotificationShown,
  NotificationPermission,
  BadgeResult,
  ShortcutInfo,
  ShortcutRegistered,
  MenuItemInfo,
  MenuItemRegistered,
} from "../../src/desktop-rails";

import type { DesktopRailsAPI, BridgeComponent as BridgeComponentClass, BridgeResponse } from "../../src/desktop-rails";

/** The main Desktop Rails API (from `window.DesktopRails`). */
export declare const DesktopRails: DesktopRailsAPI;

/** The BridgeComponent base class for native communication. */
export declare const BridgeComponent: typeof BridgeComponentClass;

/** Factory to create Stimulus-compatible bridge controller mixins. */
export declare const stimulusBridge: DesktopRailsAPI["stimulusBridge"];

/** Check if the current environment is a Desktop Rails shell. */
export declare function isDesktopRails(): boolean;
