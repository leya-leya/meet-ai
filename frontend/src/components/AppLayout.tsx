import { NavLink, Outlet } from "react-router-dom";

export default function AppLayout() {
  return (
    <div className="app-shell">
      <header className="app-header">
        <div className="header-inner">
          <NavLink className="brand" to="/">
            AI 会议纪要
          </NavLink>
          <nav aria-label="主导航" className="main-nav">
            <NavLink to="/">上传</NavLink>
            <NavLink to="/history">历史记录</NavLink>
          </nav>
        </div>
      </header>
      <main className="page-container">
        <Outlet />
      </main>
    </div>
  );
}
