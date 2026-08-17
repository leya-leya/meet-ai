import type { RecordItem } from "../types/record";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? "/api";

async function requestResponse(
  path: string,
  options?: RequestInit,
): Promise<Response> {
  const response = await fetch(`${API_BASE_URL}${path}`, options);
  if (!response.ok) {
    const payload = (await response.json().catch(() => null)) as {
      detail?: string;
    } | null;
    throw new Error(payload?.detail ?? "请求失败");
  }
  return response;
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await requestResponse(path, options);
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

export function updateRecord(
  recordId: string,
  changes: Pick<RecordItem, "title" | "summary" | "transcript">,
): Promise<RecordItem> {
  return request<RecordItem>(`/records/${encodeURIComponent(recordId)}`, {
    body: JSON.stringify(changes),
    headers: { "Content-Type": "application/json" },
    method: "PATCH",
  });
}

export async function downloadRecord(
  recordId: string,
  format: "txt" | "md",
): Promise<{ blob: Blob; filename: string }> {
  const response = await requestResponse(
    `/records/${encodeURIComponent(recordId)}/export/${format}`,
  );
  const contentDisposition = response.headers.get("Content-Disposition");
  const encodedFilename = contentDisposition?.match(
    /filename\*=UTF-8''([^;]+)/i,
  )?.[1];
  let filename = `record.${format}`;
  if (encodedFilename) {
    try {
      filename = decodeURIComponent(encodedFilename);
    } catch {
      filename = `record.${format}`;
    }
  }
  return { blob: await response.blob(), filename };
}

export function deleteRecord(recordId: string): Promise<void> {
  return request<void>(`/records/${encodeURIComponent(recordId)}`, {
    method: "DELETE",
  });
}
