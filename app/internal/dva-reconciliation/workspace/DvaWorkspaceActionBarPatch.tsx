"use client";

import { useEffect } from "react";

const STYLE_ID = "dva-workspace-action-bar-patch";

const CSS = `
  div.fixed.inset-x-0.bottom-0.z-40 {
    max-height: 96px !important;
    overflow: hidden !important;
    padding: 0.35rem 0.75rem !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div {
    display: grid !important;
    grid-template-columns: minmax(330px, 0.85fr) minmax(420px, 1.15fr) !important;
    align-items: center !important;
    gap: 0.5rem !important;
    font-size: 0.75rem !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child {
    display: flex !important;
    flex-wrap: wrap !important;
    align-items: center !important;
    gap: 0.15rem 0.7rem !important;
    min-width: 0 !important;
    overflow: hidden !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child p {
    margin: 0 !important;
    line-height: 1.1 !important;
    white-space: nowrap !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:first-child p:last-child {
    flex-basis: 100% !important;
    overflow: hidden !important;
    text-overflow: ellipsis !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 > div > div:nth-child(2) {
    display: flex !important;
    flex-wrap: nowrap !important;
    justify-content: flex-end !important;
    gap: 0.4rem !important;
    min-width: 0 !important;
    overflow-x: auto !important;
    padding: 0 !important;
  }

  div.fixed.inset-x-0.bottom-0.z-40 button,
  div.fixed.inset-x-0.bottom-0.z-40 select,
  div.fixed.inset-x-0.bottom-0.z-40 input {
    min-height: 1.85rem !important;
    padding-top: 0.25rem !important;
    padding-bottom: 0.25rem !important;
    white-space: nowrap !important;
  }

  @media (max-width: 900px) {
    div.fixed.inset-x-0.bottom-0.z-40 {
      max-height: 132px !important;
    }

    div.fixed.inset-x-0.bottom-0.z-40 > div {
      grid-template-columns: 1fr !important;
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
