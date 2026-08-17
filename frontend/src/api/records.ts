import type { RecordItem } from "../types/record";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? "/api";

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, options);
  if (!response.ok) {
    const payload = (await response.json().catch(() => null)) as {
      detail?: string;
    } | null;
    throw new Error(payload?.detail ?? "请求失败");
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

export function uploadRecord(file: File): Promise<RecordItem> {
  const formData = new FormData();
  formData.append("file", file);
  return request<RecordItem>("/records", {
    body: formData,
    method: "POST",
  });
}

export function processRecord(recordId: string): Promise<RecordItem> {
  return request<RecordItem>(
    `/records/${encodeURIComponent(recordId)}/process`,
    { method: "POST" },
  );
}

export function listRecords(query?: string): Promise<RecordItem[]> {
  const search = query ? `?q=${encodeURIComponent(query)}` : "";
  return request<RecordItem[]>(`/records${search}`);
}

export function getRecord(recordId: string): Promise<RecordItem> {
  return request<RecordItem>(`/records/${encodeURIComponent(recordId)}`);
}

export function deleteRecord(recordId: string): Promise<void> {
  return request<void>(`/records/${encodeURIComponent(recordId)}`, {
    method: "DELETE",
  });
}
