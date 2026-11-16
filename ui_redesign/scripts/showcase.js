// Shared showcase controller for Plezy UI Redesign Prototypes
(function () {
  const ACCENT_KEY = 'plezy_redesign_accent';
  const PLATFORM_KEY = 'plezy_redesign_platform';
  let toastTimer = null;

  function getActivePlatform() {
    const activeBtn = document.querySelector('.seg-btn[data-platform].active');
    return activeBtn ? activeBtn.dataset.platform : (localStorage.getItem(PLATFORM_KEY) || 'desktop');
  }

  function applyAccent(accent) {
    document.documentElement.setAttribute('data-accent', accent);
    localStorage.setItem(ACCENT_KEY, accent);
    document.querySelectorAll('.accent-dot').forEach((dot) => {
      dot.classList.toggle('active', dot.dataset.accent === accent);
    });
  }

  function panelMatches(panel, platform) {
    return (panel.dataset.platform || '').split(/\s+/).includes(platform);
  }

  function applyPlatform(platform) {
    const panels = Array.from(document.querySelectorAll('.stage-panel'));
    const hasMatch = panels.some((panel) => panelMatches(panel, platform));
    const target = hasMatch ? platform : ((panels[0]?.dataset.platform || 'desktop').split(/\s+/)[0]);

    document.documentElement.setAttribute('data-view-mode', target);
    panels.forEach((panel) => {
      panel.classList.toggle('active', panelMatches(panel, target));
    });
    document.querySelectorAll('.seg-btn[data-platform]').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.platform === target);
    });
    localStorage.setItem(PLATFORM_KEY, target);
  }

  function showToast(msg) {
    if (!msg) return;
    let toast = document.getElementById('protoToast');
    if (!toast) {
      toast = document.createElement('div');
      toast.id = 'protoToast';
      toast.className = 'proto-toast';
      document.body.appendChild(toast);
    }
    toast.textContent = msg;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 2200);
  }

  function openModal(id) {
    const modal = document.getElementById(id);
    if (!modal) return;
    document.querySelectorAll('.proto-modal.open').forEach((m) => m.classList.remove('open'));
    modal.classList.add('open');
  }

  function closeAllModals() {
    document.querySelectorAll('.proto-modal.open').forEach((m) => m.classList.remove('open'));
  }

  function initInteractivePills() {
    document.querySelectorAll('[data-pill-group]').forEach((group) => {
      const buttons = group.querySelectorAll('[data-pill]');
      buttons.forEach((btn) => {
        btn.addEventListener('click', () => {
          buttons.forEach((b) => b.classList.remove('active'));
          btn.classList.add('active');
        });
      });
    });

    document.querySelectorAll('[data-toggle-target]').forEach((trigger) => {
      trigger.addEventListener('click', (e) => {
        e.stopPropagation();
        const targetId = trigger.getAttribute('data-toggle-target');
        const el = document.getElementById(targetId);
        if (el) {
          el.classList.toggle('open');
          trigger.classList.toggle('active');
        }
      });
    });

    // Modals
    document.querySelectorAll('[data-open-modal]').forEach((trigger) => {
      trigger.addEventListener('click', (e) => {
        e.stopPropagation();
        openModal(trigger.getAttribute('data-open-modal'));
      });
    });

    document.querySelectorAll('[data-close-modal]').forEach((btn) => {
      btn.addEventListener('click', () => closeAllModals());
    });

    document.querySelectorAll('.proto-modal').forEach((modal) => {
      modal.addEventListener('click', (e) => {
        if (e.target === modal) closeAllModals();
      });
    });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') closeAllModals();
    });

    // Modal internal tab switching
    document.querySelectorAll('[data-tab-target]').forEach((tabBtn) => {
      tabBtn.addEventListener('click', () => {
        const target = tabBtn.getAttribute('data-tab-target');
        const container = tabBtn.closest('.proto-dialog') || document;
        container.querySelectorAll('[data-tab-target]').forEach((b) => b.classList.toggle('active', b === tabBtn));
        container.querySelectorAll('[data-tab-panel]').forEach((panel) => {
          panel.style.display = panel.getAttribute('data-tab-panel') === target ? 'flex' : 'none';
        });
      });
    });

    // Cross-page navigation preserving current platform
    document.querySelectorAll('[data-nav]').forEach((el) => {
      el.addEventListener('click', (e) => {
        if (e.target.closest('[data-open-modal], [data-toast]')) return;
        const dest = el.getAttribute('data-nav');
        if (!dest) return;
        const sep = dest.includes('?') ? '&' : '?';
        const platform = getActivePlatform();
        window.location.href = platform && !dest.includes('platform=') ? `${dest}${sep}platform=${platform}` : dest;
      });
    });

    // Toast feedback
    document.querySelectorAll('[data-toast]').forEach((el) => {
      el.addEventListener('click', (e) => {
        e.stopPropagation();
        showToast(el.getAttribute('data-toast'));
      });
    });
  }

  window.plezyProto = { showToast, openModal, closeAllModals };

  document.addEventListener('DOMContentLoaded', () => {
    const savedAccent = localStorage.getItem(ACCENT_KEY) || 'glacier';
    applyAccent(savedAccent);

    document.querySelectorAll('.accent-dot').forEach((dot) => {
      dot.addEventListener('click', () => applyAccent(dot.dataset.accent));
    });

    const urlParams = new URLSearchParams(window.location.search);
    const paramPlatform = urlParams.get('platform');
    const savedPlatform = paramPlatform || localStorage.getItem(PLATFORM_KEY) || 'desktop';
    applyPlatform(savedPlatform);

    document.querySelectorAll('.seg-btn[data-platform]').forEach((btn) => {
      btn.addEventListener('click', () => applyPlatform(btn.dataset.platform));
    });

    initInteractivePills();
  });
})();
