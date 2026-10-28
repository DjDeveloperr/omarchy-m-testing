document.querySelectorAll("button.model-toggle").forEach((button) => {
  const history = document.getElementById(button.getAttribute("aria-controls"));
  if (!history) return;

  const setExpanded = (expanded) => {
    history.hidden = !expanded;
    button.setAttribute("aria-expanded", String(expanded));
    button.textContent = `${expanded ? "Hide" : "Show"} builds (${button.dataset.buildCount})`;
  };

  setExpanded(false);
  button.hidden = false;
  button.addEventListener("click", () => {
    setExpanded(button.getAttribute("aria-expanded") !== "true");
  });
});
