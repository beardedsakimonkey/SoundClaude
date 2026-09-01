import "@testing-library/jest-dom/vitest";
import { vi } from "vitest";

vi.mock("@stylexjs/stylex", () => ({
  create: <Styles extends Record<string, unknown>>(styles: Styles) => styles,
  props: () => ({}),
}));

Object.defineProperty(HTMLMediaElement.prototype, "load", {
  configurable: true,
  value: vi.fn(),
});
Object.defineProperty(HTMLMediaElement.prototype, "play", {
  configurable: true,
  value: vi.fn().mockResolvedValue(undefined),
});
Object.defineProperty(HTMLMediaElement.prototype, "pause", {
  configurable: true,
  value: vi.fn(),
});
