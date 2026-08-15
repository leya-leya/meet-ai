import { Route, Routes } from "react-router-dom";

import AppLayout from "./components/AppLayout";
import HistoryPage from "./pages/HistoryPage";
import RecordDetailPage from "./pages/RecordDetailPage";
import UploadPage from "./pages/UploadPage";

export default function App() {
  return (
    <Routes>
      <Route element={<AppLayout />}>
        <Route path="/" element={<UploadPage />} />
        <Route path="/history" element={<HistoryPage />} />
        <Route path="/records/:id" element={<RecordDetailPage />} />
      </Route>
    </Routes>
  );
}
