"use client";

import { useEffect } from "react";

function applyCreditNoteDateRequirement() {
  const dateInputs = Array.from(document.querySelectorAll<HTMLInputElement>('input[name="credit_note_date"]'));

  for (const input of dateInputs) {
    input.required = true;
    input.setAttribute("aria-required", "