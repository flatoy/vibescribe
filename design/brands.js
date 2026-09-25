// Brand registry for mockups.html. Each brand is the same page with a different
// theme stylesheet (themes/<id>.css). Spectrum is the default and needs no file.
const BRANDS = [
  {
    id: "spectrum", name: "Spectrum",
    concept: "Dark glass, as the overlay is today. The icon's seven colours become the waveform, the download progress and the only colour in the UI.",
    type: "SF Pro in the app · Bricolage Grotesque for display · IBM Plex Mono for keys and numbers",
    shape: "12 px windows, 10 px panels, soft shadows, translucent surfaces",
    palette: ["#1E1E21", "#6EC6EA", "#7BA3F0", "#9A8AE6", "#D884C4", "#EDBB7A"],
  },
  {
    id: "studio", name: "Studio",
    concept: "A piece of studio gear. Warm graphite hardware, labels printed in condensed caps, raised keys, and a segmented LED level meter that runs from green through amber to red.",
    type: "Archivo (condensed and expanded widths) · JetBrains Mono for readouts",
    shape: "Tight 4–6 px corners, bevelled keys, brushed surface, segmented meters",
    palette: ["#1F1E1C", "#34312E", "#EDE6D8", "#9BD84E", "#FFB000", "#FF4B3A"],
  },
  {
    id: "steno", name: "Steno",
    concept: "A stenographer's pad. Cool white paper, navy ink, thin drawn outlines instead of shadows. Highlighter yellow marks what's live or selected, and transcripts appear in typewriter type.",
    type: "Atkinson Hyperlegible for the UI · Courier Prime for titles and transcripts",
    shape: "Light mode, 1 px ink outlines, flat surfaces, ruled writing areas",
    palette: ["#FBFCFD", "#E6EAF0", "#1C2B4A", "#2A5BD7", "#FFE34D", "#E5484D"],
  },
  {
    id: "signal", name: "Signal",
    concept: "Loud and friendly. Chunky pills, 2 px black outlines, hard offset shadows and flat saturated colour blocks. Every state gets its own colour.",
    type: "Unbounded for display · Figtree for the UI · Space Mono for keys",
    shape: "Round 14–18 px corners, true pills, hard 3–4 px drop shadows, generous padding",
    palette: ["#FFFFFF", "#111111", "#3B3BF5", "#22C98B", "#FFC931", "#FF5C47"],
  },
  {
    id: "nocturne", name: "Nocturne",
    concept: "Late-night quiet. Deep indigo layers, lilac light and peach for recording. A thin oscilloscope-style trace, a large serif, and lots of breathing room.",
    type: "Instrument Serif for titles · Geist for the UI · Geist Mono for numbers",
    shape: "Soft 14–16 px corners, no outlines, tonal layers, roomier rows",
    palette: ["#16142B", "#221F42", "#B7A5FF", "#EDB0D0", "#FFB59A", "#EEEAFB"],
  },
];

(function () {
  const params = new URLSearchParams(location.search);
  const brand = BRANDS.find((b) => b.id === params.get("brand")) || BRANDS[0];
  document.documentElement.dataset.brand = brand.id;
  const link = document.getElementById("theme-css");
  if (link && brand.id !== "spectrum") link.href = `themes/${brand.id}.css`;
  document.title = `VibeScribe — ${brand.name}`;

  document.addEventListener("DOMContentLoaded", () => {
    const bar = document.getElementById("brandbar");
    if (bar) {
      bar.innerHTML =
        `<span class="lbl">Brand</span>` +
        BRANDS.map((b) =>
          `<a href="?brand=${b.id}${location.hash}"${b.id === brand.id ? ' aria-current="page"' : ""}>` +
          `<i style="background:linear-gradient(135deg,${b.palette[0]} 0 50%,${b.palette[3]} 50%)"></i>${b.name}</a>`
        ).join("") +
        `<span class="sp"></span><a class="alt" href="variations.html">Layout directions →</a>`;
      // keep the current section when switching brand
      bar.querySelectorAll("a[href^='?brand']").forEach((a) =>
        a.addEventListener("click", () => { a.href = a.href.split("#")[0] + location.hash; })
      );
    }
    const note = document.getElementById("brand-note");
    if (note) {
      note.innerHTML =
        `<b>Brand</b><div><strong style="color:var(--ink)">${brand.name}.</strong> ${brand.concept}</div>` +
        `<b>Type</b><div>${brand.type}</div>` +
        `<b>Shape</b><div>${brand.shape}</div>` +
        `<b>Palette</b><div class="swatches">${brand.palette.map((c) => `<i style="background:${c}" title="${c}"></i>`).join("")}</div>`;
    }
    const foot = document.getElementById("toc-foot");
    if (foot) foot.innerHTML = `Brand: ${brand.name}<br>${BRANDS.indexOf(brand) + 1} of ${BRANDS.length}`;
  });
})();
