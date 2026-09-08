import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { HashRouter, Navigate, Route, Routes } from "react-router-dom";
import { AuthProvider, useAuth } from "./auth";
import { ToastProvider } from "./components/Toast";
import { Layout } from "./Layout";
import { LoginScreen } from "./Login";
import { GeneratePage } from "./pages/Generate";
import { QueuePage } from "./pages/Queue";
import { GalleryPage } from "./pages/Gallery";
import { ModelsPage } from "./pages/Models";
import { DashboardPage } from "./pages/Dashboard";
import "./styles.css";

function Gate() {
  const { authenticated, checking } = useAuth();
  if (checking) {
    return (
      <div className="login-screen">
        <p className="muted">Chargement…</p>
      </div>
    );
  }
  if (!authenticated) return <LoginScreen />;
  return (
    <HashRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<GeneratePage />} />
          <Route path="queue" element={<QueuePage />} />
          <Route path="gallery" element={<GalleryPage />} />
          <Route path="models" element={<ModelsPage />} />
          <Route path="dashboard" element={<DashboardPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </HashRouter>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AuthProvider>
      <ToastProvider>
        <Gate />
      </ToastProvider>
    </AuthProvider>
  </StrictMode>,
);
