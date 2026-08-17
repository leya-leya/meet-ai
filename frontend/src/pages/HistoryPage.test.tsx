// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vitest";

import App from "../App";
import type { RecordItem } from "../types/record";

const completedRecord: RecordItem = {
  id: "record-123",
  title: "周会复盘",
  original_filename: "weekly-meeting.mp3",
  file_type: ".mp3",
  file_size: 1024,
  status: "completed",
  transcript: "完整转写",
  summary: "AI 摘要",
  error_message: null,
  created_at: "2026-08-17T09:30:00",
  updated_at: "2026-08-17T09:35:00",
};

const uploadedRecord: RecordItem = {
  ...completedRecord,
  id: "record-456",
  title: "产品讨论",
  original_filename: "product-review.mov",
  file_type: ".mov",
  status: "uploaded",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" },
    status,
  });
}

function renderHistory() {
  return render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
      initialEntries={["/history"]}
    >
      <App />
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

test("loads records and opens a record detail from its title", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValue(jsonResponse([completedRecord, uploadedRecord]));
  vi.stubGlobal("fetch", fetchMock);
  renderHistory();

  const titleLink = await screen.findByRole("link", { name: "周会复盘" });
  expect(screen.getByText("weekly-meeting.mp3")).toBeTruthy();
  expect(screen.getByText(".mp3")).toBeTruthy();
  expect(screen.getByText("已完成")).toBeTruthy();
  expect(screen.getByText("产品讨论")).toBeTruthy();
  expect(screen.getByText("已上传")).toBeTruthy();
  expect(screen.getAllByText(/2026/).length).toBe(2);
  expect(fetchMock.mock.calls[0][0]).toBe("/api/records");

  await user.click(titleLink);
  expect(screen.getByRole("heading", { name: "记录详情" })).toBeTruthy();
});

test("submits a title query through the records API", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse([completedRecord, uploadedRecord]))
    .mockResolvedValueOnce(jsonResponse([completedRecord]));
  vi.stubGlobal("fetch", fetchMock);
  renderHistory();
  await screen.findByText("产品讨论");

  await user.type(screen.getByLabelText("搜索标题"), "周会 & 复盘");
  await user.click(screen.getByRole("button", { name: "搜索" }));

  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  expect(fetchMock.mock.calls[1][0]).toBe(
    "/api/records?q=%E5%91%A8%E4%BC%9A%20%26%20%E5%A4%8D%E7%9B%98",
  );
  expect(screen.queryByText("产品讨论")).toBeNull();
  expect(screen.getByText("周会复盘")).toBeTruthy();
});

test("confirms one deletion and refreshes the current list", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse([completedRecord]))
    .mockResolvedValueOnce(new Response(null, { status: 204 }))
    .mockResolvedValueOnce(jsonResponse([]));
  const confirmMock = vi.fn(() => true);
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("confirm", confirmMock);
  renderHistory();

  const recordCard = (await screen.findByText("周会复盘")).closest("article");
  expect(recordCard).not.toBeNull();
  await user.click(within(recordCard as HTMLElement).getByRole("button", { name: "删除" }));

  expect(confirmMock).toHaveBeenCalledWith("确认删除“周会复盘”？");
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3));
  expect(fetchMock.mock.calls[1]).toEqual([
    "/api/records/record-123",
    { method: "DELETE" },
  ]);
  expect(fetchMock.mock.calls[2][0]).toBe("/api/records");
  expect(await screen.findByText("暂无历史记录")).toBeTruthy();
});

test("keeps the record when deletion is cancelled", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValue(jsonResponse([completedRecord]));
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("confirm", vi.fn(() => false));
  renderHistory();

  await user.click(await screen.findByRole("button", { name: "删除" }));

  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(screen.getByText("周会复盘")).toBeTruthy();
});

test("keeps the newest search result when deletion refresh overlaps it", async () => {
  const user = userEvent.setup();
  let finishDelete: (response: Response) => void = () => undefined;
  let finishSearch: (response: Response) => void = () => undefined;
  let finishRefresh: (response: Response) => void = () => undefined;
  const deleteResponse = new Promise<Response>((resolve) => {
    finishDelete = resolve;
  });
  const searchResponse = new Promise<Response>((resolve) => {
    finishSearch = resolve;
  });
  const refreshResponse = new Promise<Response>((resolve) => {
    finishRefresh = resolve;
  });
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse([completedRecord]))
    .mockReturnValueOnce(deleteResponse)
    .mockReturnValueOnce(searchResponse)
    .mockReturnValueOnce(refreshResponse);
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("confirm", vi.fn(() => true));
  renderHistory();

  await user.click(await screen.findByRole("button", { name: "删除" }));
  await user.type(screen.getByLabelText("搜索标题"), "产品");
  await user.click(screen.getByRole("button", { name: "搜索" }));
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3));

  finishDelete(new Response(null, { status: 204 }));
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(4));
  expect(fetchMock.mock.calls[3][0]).toBe(
    "/api/records?q=%E4%BA%A7%E5%93%81",
  );

  finishRefresh(jsonResponse([uploadedRecord]));
  expect(await screen.findByText("产品讨论")).toBeTruthy();
  finishSearch(jsonResponse([completedRecord]));
  await waitFor(() => expect(screen.queryByText("周会复盘")).toBeNull());
  expect(screen.getByText("产品讨论")).toBeTruthy();
});

test("shows a delete API error without refreshing the list", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse([completedRecord]))
    .mockResolvedValueOnce(jsonResponse({ detail: "记录删除失败" }, 500));
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("confirm", vi.fn(() => true));
  renderHistory();

  await user.click(await screen.findByRole("button", { name: "删除" }));

  expect((await screen.findByRole("alert")).textContent).toBe("记录删除失败");
  expect(fetchMock).toHaveBeenCalledTimes(2);
  expect(screen.getByText("周会复盘")).toBeTruthy();
});

test("shows a clear records API error", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse({ detail: "历史记录读取失败" }, 500),
    ),
  );
  renderHistory();

  expect((await screen.findByRole("alert")).textContent).toBe("历史记录读取失败");
});
