import { useEffect } from "react";
import { NavLink, Outlet, useLocation } from "react-router-dom";
import { useAuth } from "./auth";
import { Aurora, Monogram } from "./components/Aurora";

const NAV = [
  { to: "/", label: "Générer", icon: "✨", end: true },
  { to: "/queue", label: "File d'attente", icon: "≡" },
  { to: "/gallery", label: "Galerie", icon: "🖼" },
  { to: "/models", label: "Modèles", icon: "🧠" },
  { to: "/dashboard", label: "Tableau de bord", icon: "📊" },
];

export function Layout() {
  const { logout, username } = useAuth();
  const location = useLocation();

  useEffect(() => {
    // scroll main content to top on navigation
    document.querySelector("main")?.scrollTo(0, 0);
  }, [location.pathname]);

  return (
    <div className="layout">
      <Aurora />
      <header className="topbar glass">
        <span className="brand">
          <Monogram size={26} />
          <span className="brand-text">
            MLXBits <strong>Image Studio</strong>
          </span>
        </span>
        <span className="topbar-chip tnum">
          {username ?? "Hub"}
        </span>
      </header>
      <div className="body">
        <nav className="sidebar glass">
          <div className="nav-items">
            {NAV.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.end}
                className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`}
              >
                <span className="nav-indicator" aria-hidden />
                <span className="nav-icon" aria-hidden>
                  {item.icon}
                </span>
                <span>{item.label}</span>
              </NavLink>
            ))}
          </div>
          <div className="sidebar-footer">
            <button className="nav-logout" onClick={() => void logout()}>
              <span className="nav-icon" aria-hidden>
                ⎋
              </span>
              <span>Déconnexion</span>
            </button>
          </div>
        </nav>
        <main className="main" key={location.pathname}>
          <div className="page-enter">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  );
}
