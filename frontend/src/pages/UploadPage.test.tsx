// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vitest";

import App from "../App";
import UploadPage from "./UploadPage";


afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});


test("requires one supported media file before upload can start", async () => {
  const user = userEvent.setup();
  render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
    >
      <UploadPage />
    </MemoryRouter>,
  );

  expect(screen.getByText("MP3、WAV、M4A、MP4、MOV")).toBeTruthy();
  expect(screen.getByText("单个文件最大 500 MB")).toBeTruthy();

  const fileInput = screen.getByLabelText("选择音视频文件");
  const submitButton = screen.getByRole("button", { name: "上传并处理" });
  expect(fileInput.getAttribute("multiple")).toBeNull();
  expect(submitButton).toHaveProperty("disabled", true);

  await user.upload(
    fileInput,
    new File(["audio"], "weekly-meeting.mp3", { type: "audio/mpeg" }),
  );

  expect(screen.getByText("已选择：weekly-meeting.mp3")).toBeTruthy();
  expect(submitButton).toHaveProperty("disabled", false);
});


test("uploads then processes the selected file before opening its detail page", async () => {
  const user = userEvent.setup();
  const uploadedRecord = {
    id: "record-123",
    title: "weekly-meeting",
    original_filename: "weekly-meeting.mp3",
    file_type: ".mp3",
    file_size: 5,
    status: "uploaded",
    transcript: null,
    summary: null,
    error_message: null,
    created_at: "2026-08-17T09:00:00",
    updated_at: "2026-08-17T09:00:00",
  };
  let finishProcessing: (response: Response) => void = () => undefined;
  const processingResponse = new Promise<Response>((resolve) => {
    finishProcessing = resolve;
  });
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(
      new Response(JSON.stringify(uploadedRecord), {
        headers: { "Content-Type": "application/json" },
        status: 201,
      }),
    )
    .mockReturnValueOnce(processingResponse);
  vi.stubGlobal("fetch", fetchMock);
  render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
      initialEntries={["/"]}
    >
      <App />
    </MemoryRouter>,
  );

  const file = new File(["audio"], "weekly-meeting.mp3", {
    type: "audio/mpeg",
  });
  await user.upload(screen.getByLabelText("选择音视频文件"), file);
  await user.click(screen.getByRole("button", { name: "上传并处理" }));

  expect(
    await screen.findByText("当前状态：正在转写并生成摘要"),
  ).toBeTruthy();
  const uploadOptions = fetchMock.mock.calls[0][1];
  expect(fetchMock.mock.calls[0][0]).toBe("/api/records");
  expect(uploadOptions?.method).toBe("POST");
  expect(uploadOptions?.body).toBeInstanceOf(FormData);
  expect((uploadOptions?.body as FormData).get("file")).toBe(file);
  expect(fetchMock.mock.calls[1]).toEqual([
    "/api/records/record-123/process",
    { method: "POST" },
  ]);

  finishProcessing(
    new Response(
      JSON.stringify({
        ...uploadedRecord,
        status: "completed",
        transcript: "测试转写",
        summary: "测试摘要",
      }),
      { headers: { "Content-Type": "application/json" }, status: 200 },
    ),
  );

  expect(
    await screen.findByRole("heading", { name: "记录详情" }),
  ).toBeTruthy();
});


test("shows the API error and allows retrying the selected file", async () => {
  const user = userEvent.setup();
  vi.stubGlobal(
    "fetch",
    vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ detail: "上传文件保存失败" }), {
        headers: { "Content-Type": "application/json" },
        status: 500,
      }),
    ),
  );
  render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
    >
      <UploadPage />
    </MemoryRouter>,
  );

  await user.upload(
    screen.getByLabelText("选择音视频文件"),
    new File(["audio"], "retry.mp3", { type: "audio/mpeg" }),
  );
  await user.click(screen.getByRole("button", { name: "上传并处理" }));

  expect(await screen.findByText("上传文件保存失败")).toBeTruthy();
  expect(screen.getByText("当前状态：处理失败")).toBeTruthy();
  await waitFor(() => {
    expect(screen.getByRole("button", { name: "上传并处理" })).toHaveProperty(
      "disabled",
      false,
    );
  });
});


test("shows a failed processing record instead of opening its detail page", async () => {
  const user = userEvent.setup();
  const uploadedRecord = {
    id: "failed-record",
    title: "failed-meeting",
    original_filename: "failed-meeting.mp3",
    file_type: ".mp3",
    file_size: 5,
    status: "uploaded",
    transcript: null,
    summary: null,
    error_message: null,
    created_at: "2026-08-17T09:00:00",
    updated_at: "2026-08-17T09:00:00",
  };
  vi.stubGlobal(
    "fetch",
    vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        new Response(JSON.stringify(uploadedRecord), {
          headers: { "Content-Type": "application/json" },
          status: 201,
        }),
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ...uploadedRecord,
            error_message: "LLM unavailable",
            status: "failed",
            transcript: "已经生成的转写",
          }),
          { headers: { "Content-Type": "application/json" }, status: 200 },
        ),
      ),
  );
  render(
    <MemoryRouter
      future={{ v7_relativeSplatPath: true, v7_startTransition: true }}
      initialEntries={["/"]}
    >
      <App />
    </MemoryRouter>,
  );

  await user.upload(
    screen.getByLabelText("选择音视频文件"),
    new File(["audio"], "failed-meeting.mp3", { type: "audio/mpeg" }),
  );
  await user.click(screen.getByRole("button", { name: "上传并处理" }));

  expect(await screen.findByText("LLM unavailable")).toBeTruthy();
  expect(screen.getByText("当前状态：处理失败")).toBeTruthy();
  expect(screen.getByRole("heading", { name: "上传音视频" })).toBeTruthy();
});
