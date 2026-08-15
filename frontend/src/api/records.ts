import type { RecordItem } from "../types/record";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? "/api";

async function request<T>(path: string): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`);
  if (!response.ok) {
    const payload = (await response.json().catch(() => null)) as {
      detail?: string;
    } | null;
    throw new Error(payload?.detail ?? "请求失败");
  }
  return response.json() as Promise<T>;
}

export function listRecords(query?: string): Promise<RecordItem[]> {
  const search = query ? `?q=${encodeURIComponent(query)}` : "";
  return request<RecordItem[]>(`/records${search}`);
}

export function getRecord(recordId: string): Promise<RecordItem> {
  return request<RecordItem>(`/records/${encodeURIComponent(recordId)}`);
}
