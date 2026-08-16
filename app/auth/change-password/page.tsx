"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";

export default function RequiredPasswordChangePage() {
  const supabase = createClient();
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");

    if (password.length < 12) {
      setError("Use at least 12 characters for the new password.");
      return;
    }

    if (password !== confirmPassword) {
      setError("The two passwords do not match.");
      return;
    }

    setSaving(true);

    const { data: before, error: beforeError } = await supabase.auth.getUser();
    if (beforeError || !before.user) {
      setSaving(false);
      router.push("/login");
      router.refresh();
      return;
    }

    const originalAuthUserId = before.user.id;
    const { data: updated, error: passwordError } = await supabase.auth.updateUser({ password });

    if (passwordError || !updated.user) {
      setSaving(false);
      setError(passwordError?.message ?? "Password could not be changed.");
      return;
    }

    if (updated.user.id !== originalAuthUserId) {
      setSaving(false);
      setError("Authentication identity changed unexpectedly. Contact an administrator.");
      return;
    }

    const { error: completionError } = await supabase.rpc(
      "current_user_complete_required_password_change_v1",
    );

    if (completionError) {
      setSaving(false);
      setError(
        "Your password changed, but the completion flag could not be saved. Submit again to complete onboarding.",
      );
      return;
    }

    router.push("/auth/check");
    router.refresh();
  }

  return (
    <main className="min-h-screen flex items-center justify-center p-6">
      <div className="w-full max-w-md rounded-2xl border p-6 space-y-4">
        <div>
          <p className="text-sm font-medium text-slate-500">First login</p>
          <h1 className="mt-1 text-2xl font-semibold">Choose a new password</h1>
          <p className="mt-2 text-sm text-slate-600">
            Your temporary password has worked. Set your own password before continuing.
          </p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-3">
          <div className="space-y-1">
            <label htmlFor="new-password" className="block text-sm font-medium">
              New password
            </label>
            <input
              id="new-password"
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              className="w-full rounded-lg border px-3 py-2"
              autoComplete="new-password"
              minLength={12}
              required
            />
          </div>

          <div className="space-y-1">
            <label htmlFor="confirm-password" className="block text-sm font-medium">
              Confirm new password
            </label>
            <input
              id="confirm-password"
              type="password"
              value={confirmPassword}
              onChange={(event) => setConfirmPassword(event.target.value)}
              className="w-full rounded-lg border px-3 py-2"
              autoComplete="new-password"
              minLength={12}
              required
            />
          </div>

          <button
            type="submit"
            disabled={saving}
            className="w-full rounded-lg border px-3 py-2 font-medium disabled:opacity-60"
          >
            {saving ? "Saving…" : "Set password and continue"}
          </button>

          {error ? <p className="text-sm text-red-600">{error}</p> : null}
        </form>
      </div>
    </main>
  );
}
