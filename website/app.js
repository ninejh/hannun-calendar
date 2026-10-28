(() => {
  "use strict";
  const release = window.HANNUN_RELEASE;
  if (release && /^https:\/\/github\.com\/ninejh\/hannun-calendar$/.test(release.repository)) {
    const root = release.repository;
    const tag = encodeURIComponent(release.tag);
    const links = {
      repository: root,
      notes: `${root}/releases/tag/${tag}`,
      issues: `${root}/issues`,
      dmg: `${root}/releases/download/${tag}/${encodeURIComponent(release.dmg)}`,
      zip: `${root}/releases/download/${tag}/${encodeURIComponent(release.zip)}`
    };
    document.querySelectorAll("[data-release-link]").forEach(link => {
      const href = links[link.dataset.releaseLink];
      if (href) link.href = href;
    });
    document.querySelectorAll("[data-release-version]").forEach(node => { node.textContent = release.tag; });
  }

})();
