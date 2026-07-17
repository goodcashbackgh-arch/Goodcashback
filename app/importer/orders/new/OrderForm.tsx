"use client";

import { useRef, useState, useTransition, type ChangeEvent, type FormEvent } from "react";

type Option = { id: string; name: string };
type Hub = { id: string; name: string; city?: string | null };
type AttachmentSummary = {
  count: number;
  originalBytes: number;
  uploadBytes: number;
  optimised: boolean;
  error: string;
};

const MAX_ATTACHMENT_BYTES = 3.5