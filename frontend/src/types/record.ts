export type RecordStatus =
  | "uploaded"
  | "transcribing"
  | "transcribed"
  | "summarizing"
  | "completed"
  | "failed";

export interface RecordItem {
  id: string;
  title: string;
  original_filename: string;
  file_type: string;
  file_size: number;
  status: RecordStatus;
  transcript: string | null;
  summary: string | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
}
