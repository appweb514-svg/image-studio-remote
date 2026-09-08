import { useEffect } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAuth } from "./auth";

const NAV = [
  { to: "/", label: "Générer", icon: "✨", end: true },
  { to: "/queue", label: "File d'attente", icon: "≡" },
  { to: "/gallery", label: "Galerie", icon: "🖼" },
  { to: "/models", label: "Modèles", icon: "🧠" },
  { to: "/dashboard", label: "Tableau de bord", icon: "📊" },
];

export function Layout() {
  const { logout } = useAuth();
  const location = useLocation();

  useEffect(() => {
    // scroll main content to top on navigation
    document.querySelector("main")?.scrollTo(0, 0);
  }, [location.pathname]);

  return (
    <div className="layout">
      <header className="topbar">
        <span className="brand">MLXBits <strong>Image Studio</strong></span>
        <button className="btn btn-ghost" onClick={() => void logout()}>
          Déconnexion
        </button>
      </header>
      <div className="body">
        <nav className="sidebar">
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`}
            >
              <span className="nav-icon" aria-hidden>
                {item.icon}
              </span>
              <span>{item.label}</span>
            </NavLink>
          ))}
        </nav>
        <main className="main">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
