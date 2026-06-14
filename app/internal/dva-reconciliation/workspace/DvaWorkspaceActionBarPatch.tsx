"use client";

import { useEffect } from "react";

const STYLE_ID = "dva-workspace-action-bar-patch";

const CSS = `
  div.fixed.inset-x-0.bottom-0.z-40 {
    max-height: min(42vh, 260px) !important;
    overflow-y: auto !important;
    overflow-x: hidden !important;
    padding: 0.65rem 1rem !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div {
    display: grid !important;
    grid-template-columns: minmax(320px, 1fr) minmax(360px, auto) !important;
    align-items: end !important;
    gap: 0.75rem !important;
    font-size: 0.78rem !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child {
    display: flex !important;
    flex-wrap: wrap !important;
    align-items: center !important;
    gap: 0.15rem 0.85rem !important;
    min-width: 0 !important;
    overflow: visible !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child p {
    margin: 0 !important;
    line-height: 1.15 !important;
    white-space: nowrap !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child p:last-child {
    flex-basis: 100% !important;
    white-space: normal !important;
    overflow: visible !important;
    text-overflow: clip !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:nth-child(2) {
    display: flex !important;
    flex-wrap: wrap !important;
    justify-content: flex-end !important;
    gap: 0.45rem !important;
    min-width: 0 !important;
    overflow: visible !important;
    padding: 0 !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 form {
    margin: 0 !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 button,
  div.fixed.inset-x-0.bottom-0.z-40 select,
  div.fixed.inset-x-0.bottom-0.z-40 input {
    min-height: 1.9rem !important;
    padding-top: 0.25rem !important;
    padding-bottom: 0.25rem !important;
    white-space: nowrap !important;
  }

  @media (max-width: 900px) {
    div.fixed.inset-x-0.bottom-0.z-40 {
      max-height: 48vh !important;
    }

    div.fixed.inset-x-0.bottom-0.z-40 > div {
      grid-template-columns: 1fr !important;
      align-items: start !important;
    }

    div.fixed.inset-x-0.bottom-0.z-40 > div > div:nth-child(2) {
      justify-content: flex-start !important;
    }
  }
`;

export default function DvaWorkspaceActionBarPatch() {
  useEffect(() => {
    document.getElementById(STYLE_ID)?.remove();

    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = CSS;
    document.head.appendChild(style);

    return () => {
      document.getElementById(STYLE_ID)?.remove();
    };
  }, []);

  return null;
}
