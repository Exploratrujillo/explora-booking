export default function BookingSummary({ booking, experience }) {
  const adultTotal =
    experience?.adultPrice != null ? booking.adults * experience.adultPrice : 0;
  const childTotal =
    experience?.childPrice != null ? booking.children * experience.childPrice : 0;
  const total =
    experience?.adultPrice == null ? null : adultTotal + childTotal;

  return (
    <aside className="booking-summary">
      <p className="eyebrow">RESUMEN</p>
      <h2>Tu reserva</h2>

      {!experience ? (
        <p className="summary-empty">Selecciona una experiencia para comenzar.</p>
      ) : (
        <>
          <div className={`summary-image ${experience.imageClass}`}>
            <div className="landmark">♜</div>
          </div>

          <h3>{experience.name}</h3>
          <p>{experience.subtitle}</p>

          <dl>
            <div>
              <dt>Fecha</dt>
              <dd>{booking.date || "Sin elegir"}</dd>
            </div>
            <div>
              <dt>Hora</dt>
              <dd>{booking.time || "Sin elegir"}</dd>
            </div>
            <div>
              <dt>Adultos</dt>
              <dd>{booking.adults}</dd>
            </div>
            <div>
              <dt>Niños</dt>
              <dd>{booking.children}</dd>
            </div>
          </dl>

          <div className="summary-total">
            <span>Total</span>
            <strong>{total == null ? "A consultar" : `${total.toFixed(2).replace(".", ",")} €`}</strong>
          </div>

          <small className="summary-note">
            El pago se realizará presencialmente. La reserva no genera ningún
            cargo online.
          </small>
        </>
      )}
    </aside>
  );
}
