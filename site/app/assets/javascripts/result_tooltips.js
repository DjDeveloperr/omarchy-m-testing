// Result squares (matrix cells, the Features page) carry their tooltip (.cell-tooltip) hidden; this shows it in one
// floating box on hover or focus, so the scrolling table doesn't clip it. Without
// JavaScript the cell's title attribute still explains it.
const floating = document.createElement("div");
floating.className = "result-tooltip floating";
floating.hidden = true;
floating.setAttribute("aria-hidden", "true");
document.body.append(floating);

let target = null;
const ARROW = 7; // the pointer's height, so the box touches the square

const show = (cell) => {
  const source = cell.querySelector(".cell-tooltip");
  if (!source) return;
  target?.classList.remove("tooltip-target");
  target = cell;
  cell.classList.add("tooltip-target");
  floating.innerHTML = source.innerHTML;
  floating.hidden = false;
  const box = cell.getBoundingClientRect();
  const { width, height } = floating.getBoundingClientRect();
  const margin = 8;
  let top = box.bottom + ARROW;
  let placement = "below";
  if (top + height > window.innerHeight - margin && box.top - height - ARROW > margin) {
    top = box.top - height - ARROW;
    placement = "above";
  }
  const centre = box.left + box.width / 2;
  const left = Math.min(Math.max(margin, centre - 24), window.innerWidth - width - margin);
  floating.dataset.placement = placement;
  floating.style.setProperty("--arrow-x", `${Math.round(centre - left)}px`);
  floating.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
};
const hide = () => {
  floating.hidden = true;
  target?.classList.remove("tooltip-target");
  target = null;
};

document.querySelectorAll(".has-tooltip").forEach((cell) => {
  cell.removeAttribute("title"); // the floating box replaces the browser's own tooltip
  cell.addEventListener("mouseenter", () => show(cell));
  cell.addEventListener("mouseleave", hide);
  cell.addEventListener("focusin", () => show(cell));
  cell.addEventListener("focusout", hide);
});
window.addEventListener("scroll", hide, { passive: true, capture: true });
