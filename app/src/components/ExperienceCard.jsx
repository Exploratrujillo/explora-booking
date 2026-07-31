export default function ExperienceCard({ experience, selected, onSelect }) {
  return (
    <article
      className={`experience-card ${selected ? "experience-card--selected" : ""}`}
      onClick={() => onSelect(experience)}
    >
      <div className={`experience-image ${experience.imageClass}`}>
        <span className="experience-badge">{experience.badge}</span>
        <div className="landmark">♜</div>
      </div>

      <div className="experience-card__content">
        <div>
          <p className="eyebrow">EXPLORA TRUJILLO</p>
          <h3>{experience.name}</h3>
          <p className="experience-subtitle">{experience.subtitle}</p>
        </div>

        <div className="experience-meta">
          <span>◷ {experience.duration}</span>
          <span>⌖ {experience.meetingPoint}</span>
        </div>

        <p className="experience-description">{experience.description}</p>

        <div className="experience-card__footer">
          <div>
            <small>Precio</small>
            <strong>{experience.priceLabel}</strong>
            <em>{experience.childLabel}</em>
          </div>
          <button type="button">
            {selected ? "Seleccionada ✓" : "Seleccionar"}
          </button>
        </div>
      </div>
    </article>
  );
}
