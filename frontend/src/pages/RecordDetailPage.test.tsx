// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from "@testing-library/react";
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

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" },
    status,
  });
}

function renderDetail() {
  return render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
      initialEntries={["/records/record-123"]}
    >
      <App />
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

test("loads a record into editable detail fields", async () => {
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValue(jsonResponse(completedRecord));
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  expect(await screen.findByDisplayValue("周会复盘")).toBeTruthy();
  expect(screen.getByLabelText("AI 摘要")).toHaveProperty("value", "AI 摘要");
  expect(screen.getByLabelText("完整转写")).toHaveProperty(
    "value",
    "完整转写",
  );
  expect(screen.getByText("weekly-meeting.mp3")).toBeTruthy();
  expect(screen.getByText("已完成")).toBeTruthy();
  expect(screen.getByText(/2026/)).toBeTruthy();
  expect(fetchMock).toHaveBeenCalledWith("/api/records/record-123", undefined);
});

test("saves title summary and transcript through PATCH and confirms success", async () => {
  const user = userEvent.setup();
  const savedRecord = {
    ...completedRecord,
    title: "新的周会标题",
    summary: "人工修改的摘要",
    transcript: "人工修改的完整转写",
  };
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse(completedRecord))
    .mockResolvedValueOnce(jsonResponse(savedRecord));
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  const titleInput = await screen.findByLabelText("标题");
  await user.clear(titleInput);
  await user.type(titleInput, savedRecord.title);
  await user.clear(screen.getByLabelText("AI 摘要"));
  await user.type(screen.getByLabelText("AI 摘要"), savedRecord.summary);
  await user.clear(screen.getByLabelText("完整转写"));
  await user.type(
    screen.getByLabelText("完整转写"),
    savedRecord.transcript,
  );
  await user.click(screen.getByRole("button", { name: "保存修改" }));

  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  expect(fetchMock.mock.calls[1]).toEqual([
    "/api/records/record-123",
    {
      body: JSON.stringify({
        title: savedRecord.title,
        summary: savedRecord.summary,
        transcript: savedRecord.transcript,
      }),
      headers: { "Content-Type": "application/json" },
      method: "PATCH",
    },
  ]);
  expect((await screen.findByRole("status")).textContent).toBe("保存成功");
});

test("rejects a blank title before sending PATCH", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValue(jsonResponse(completedRecord));
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  const titleInput = await screen.findByLabelText("标题");
  await user.clear(titleInput);
  await user.type(titleInput, "   ");
  await user.click(screen.getByRole("button", { name: "保存修改" }));

  expect((await screen.findByRole("alert")).textContent).toBe("标题不能为空");
  expect(fetchMock).toHaveBeenCalledTimes(1);
});

test("shows a failed record error while keeping existing content editable", async () => {
  const failedRecord: RecordItem = {
    ...completedRecord,
    status: "failed",
    error_message: "摘要服务暂时不可用",
  };
  vi.stubGlobal(
    "fetch",
    vi.fn<typeof fetch>().mockResolvedValue(jsonResponse(failedRecord)),
  );
  renderDetail();

  expect(await screen.findByText("处理失败")).toBeTruthy();
  expect(screen.getByRole("alert").textContent).toBe("摘要服务暂时不可用");
  expect(screen.getByLabelText("AI 摘要")).toHaveProperty("value", "AI 摘要");
  expect(screen.getByLabelText("完整转写")).toHaveProperty(
    "value",
    "完整转写",
  );
  expect(screen.getByLabelText("AI 摘要")).toHaveProperty("disabled", false);
  expect(screen.getByLabelText("完整转写")).toHaveProperty("disabled", false);
});

test("downloads TXT and Markdown exports from their API endpoints", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse(completedRecord))
    .mockResolvedValueOnce(
      new Response("TXT 内容", {
        headers: {
          "Content-Disposition":
            "attachment; filename=record.txt; filename*=UTF-8''%E5%91%A8%E4%BC%9A%E5%A4%8D%E7%9B%98.txt",
          "Content-Type": "text/plain",
        },
      }),
    )
    .mockResolvedValueOnce(
      new Response("# Markdown 内容", {
        headers: {
          "Content-Disposition":
            "attachment; filename=record.md; filename*=UTF-8''%E5%91%A8%E4%BC%9A%E5%A4%8D%E7%9B%98.md",
          "Content-Type": "text/markdown",
        },
      }),
    );
  const createObjectURL = vi.fn(() => "blob:record-export");
  const revokeObjectURL = vi.fn();
  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: createObjectURL,
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: revokeObjectURL,
  });
  const anchorClick = vi
    .spyOn(HTMLAnchorElement.prototype, "click")
    .mockImplementation(() => undefined);
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  await screen.findByDisplayValue("周会复盘");
  await user.click(screen.getByRole("button", { name: "下载 TXT" }));
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  await user.click(screen.getByRole("button", { name: "下载 Markdown" }));
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3));

  expect(fetchMock.mock.calls[1][0]).toBe(
    "/api/records/record-123/export/txt",
  );
  expect(fetchMock.mock.calls[2][0]).toBe("/api/records/record-123/export/md");
  expect(createObjectURL).toHaveBeenCalledTimes(2);
  expect(anchorClick).toHaveBeenCalledTimes(2);
  expect(revokeObjectURL).toHaveBeenCalledTimes(2);
});

test("shows an export API error on the detail page", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse(completedRecord))
    .mockResolvedValueOnce(jsonResponse({ detail: "导出失败" }, 500));
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  await screen.findByDisplayValue("周会复盘");
  await user.click(screen.getByRole("button", { name: "下载 TXT" }));

  expect((await screen.findByRole("alert")).textContent).toBe("导出失败");
});

test("deletes the record after confirmation and returns to history", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse(completedRecord))
    .mockResolvedValueOnce(new Response(null, { status: 204 }))
    .mockResolvedValueOnce(jsonResponse([]));
  const confirmMock = vi.fn(() => true);
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("confirm", confirmMock);
  renderDetail();

  await user.click(await screen.findByRole("button", { name: "删除记录" }));

  expect(confirmMock).toHaveBeenCalledWith("确认删除“周会复盘”？");
  expect(await screen.findByRole("heading", { name: "历史记录" })).toBeTruthy();
  expect(fetchMock.mock.calls[1]).toEqual([
    "/api/records/record-123",
    { method: "DELETE" },
  ]);
});

test("shows a save API error without losing edits", async () => {
  const user = userEvent.setup();
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(jsonResponse(completedRecord))
    .mockResolvedValueOnce(jsonResponse({ detail: "保存编辑失败" }, 500));
  vi.stubGlobal("fetch", fetchMock);
  renderDetail();

  const summary = await screen.findByLabelText("AI 摘要");
  await user.clear(summary);
  await user.type(summary, "尚未保存的摘要");
  await user.click(screen.getByRole("button", { name: "保存修改" }));

  expect((await screen.findByRole("alert")).textContent).toBe("保存编辑失败");
  expect(screen.getByLabelText("AI 摘要")).toHaveProperty(
    "value",
    "尚未保存的摘要",
  );
});
