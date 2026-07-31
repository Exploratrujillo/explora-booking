import { useMemo, useState } from "react";
import { products, formatPrice } from "../data/products";
import "../styles/Booking.css";

const steps = ["Experiencia", "Fecha", "Personas", "Datos", "Confirmación"];

function formatDate(dateString) {
  return new Intl.DateTimeFormat("es-ES", {
    weekday: "long",
    day: "numeric",
    month: "long",
  }).format(new Date(`${dateString}T12:00:00`));
}

export default function Booking() {
  const [step, setStep] = useState(1);
  const [productId, setProductId] = useState("esencial");
  const [selectedDate, setSelectedDate] = useState("");
  const [adults, setAdults] = useState(2);
  const [children, setChildren] = useState(0);
  const [babies, setBabies] = useState(0);
  const [customer, setCustomer] = useState({
    name: "",
    email: "",
    phone: "",
    city: "",
    notes: "",
    privacy: false,
  });

  const product = products.find((item) => item.id === productId);
  const dateOption = product?.dates.find(
    (item) => `${item.date}-${item.time}` === selectedDate
  );

  const total = useMemo(() => {
    if (!product || product.priceAdult === null) return null;
    return adults * product.priceAdult + children * (product.priceChild || 0);
  }, [product, adults, children]);

  function selectProduct(id) {
    setProductId(id);
    setSelectedDate("");
    setAdults(2);
    setChildren(0);
    setBabies(0);
  }

  function canContinue() {
    if (step === 1) return Boolean(product);
    if (step === 2) return productId === "privada" || Boolean(selectedDate);
    if (step === 3) return adults > 0;
    if (step === 4) {
      return (
        customer.name.trim() &&
        customer.email.trim() &&
        customer.phone.trim() &&
        customer.privacy
      );
    }
    return true;
  }

  function next() {
    if (!canContinue()) return;
    setStep((current) => Math.min(current + 1, 5));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function back() {
    setStep((current) => Math.max(current - 1, 1));
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  function updateCustomer(event) {
    const { name, value, type, checked } = event.target;
    setCustomer((current) => ({
      ...current,
      [name]: type === "checkbox" ? checked : value,
    }));
  }

  return (
    <div className="booking-page">
      <header className="booking-header">
        <button className="booking-brand" onClick={() => (window.location.hash = "/")}>
          <span className="booking-brand-mark">⌂</span>
          <span>
            <strong>EXPLORA</strong>
            <small>TRUJILLO</small>
          </span>
        </button>

        <div className="booking-help">
          <span>¿Necesitas ayuda?</span>
          <a href="tel:+34644659449">644 659 449</a>
        </div>
      </header>

      <main className="booking-shell">
        <section className="booking-intro">
          <p className="booking-kicker">RESERVA ONLINE</p>
          <h1>Prepara tu visita a Trujillo</h1>
          <p>Elige tu experiencia y completa la reserva en pocos pasos.</p>
        </section>

        <ol className="booking-steps">
          {steps.map((label, index) => {
            const number = index + 1;
            return (
              <li
                key={label}
                className={`${number === step ? "active" : ""} ${
                  number < step ? "done" : ""
                }`}
              >
                <span>{number < step ? "✓" : number}</span>
                <small>{label}</small>
              </li>
            );
          })}
        </ol>

        <div className="booking-layout">
          <section className="booking-card booking-main">
            {step === 1 && (
              <>
                <div className="booking-section-title">
                  <span>PASO 1</span>
                  <h2>Elige tu experiencia</h2>
                  <p>Selecciona la visita que mejor encaja contigo.</p>
                </div>

                <div className="experience-list">
                  {products.map((item) => (
                    <button
                      key={item.id}
                      className={`experience-option ${
                        productId === item.id ? "selected" : ""
                      }`}
                      onClick={() => selectProduct(item.id)}
                    >
                      <span className="experience-radio" />
                      <span className="experience-content">
                        <small>{item.eyebrow}</small>
                        <strong>{item.name}</strong>
                        <p>{item.description}</p>
                        <em>
                          {item.duration} · {item.meetingPoint}
                        </em>
                      </span>
                      <span className="experience-price">
                        <strong>{formatPrice(item.priceAdult)}</strong>
                        {item.priceAdult !== null && <small>por adulto</small>}
                      </span>
                    </button>
                  ))}
                </div>
              </>
            )}

            {step === 2 && (
              <>
                <div className="booking-section-title">
                  <span>PASO 2</span>
                  <h2>Selecciona fecha y hora</h2>
                  <p>Solo mostramos las próximas salidas programadas.</p>
                </div>

                {productId === "privada" ? (
                  <div className="private-notice">
                    <strong>Prepararemos una propuesta personalizada.</strong>
                    <p>
                      Continúa para indicarnos tus datos y preferencias. Te
                      contactaremos para confirmar fecha, horario y precio.
                    </p>
                  </div>
                ) : (
                  <div className="date-list">
                    {product.dates.map((option) => {
                      const value = `${option.date}-${option.time}`;
                      const full = option.status === "full";
                      return (
                        <button
                          key={value}
                          disabled={full}
                          className={`date-option ${
                            selectedDate === value ? "selected" : ""
                          } ${full ? "full" : ""}`}
                          onClick={() => setSelectedDate(value)}
                        >
                          <span>
                            <strong>{formatDate(option.date)}</strong>
                            <small>{option.time} h</small>
                          </span>
                          <span className="date-status">
                            {full ? "Completa" : `${option.remaining} plazas`}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                )}
              </>
            )}

            {step === 3 && (
              <>
                <div className="booking-section-title">
                  <span>PASO 3</span>
                  <h2>¿Cuántas personas asistirán?</h2>
                  <p>Aplicaremos automáticamente las reglas de cada visita.</p>
                </div>

                <Counter
                  label="Adultos"
                  detail={productId === "candil" ? "Mayores de 12 años" : "A partir de 15 años"}
                  value={adults}
                  min={1}
                  onChange={setAdults}
                />

                {productId !== "candil" && productId !== "privada" && (
                  <Counter
                    label="Niños"
                    detail={
                      productId === "exploradores"
                        ? "De 4 a 14 años"
                        : "Hasta 12 años · gratis"
                    }
                    value={children}
                    min={0}
                    onChange={setChildren}
                  />
                )}

                {productId === "exploradores" && (
                  <Counter
                    label="Menores de 3 años"
                    detail="Gratis y no consumen plaza"
                    value={babies}
                    min={0}
                    onChange={setBabies}
                  />
                )}

                {product.minimumAdults && adults < product.minimumAdults && (
                  <div className="minimum-warning">
                    <strong>Salida pendiente de garantizar</strong>
                    <p>
                      La visita necesita un mínimo de {product.minimumAdults} adultos.
                      Puedes reservar igualmente y contactaremos contigo si no se alcanza.
                    </p>
                  </div>
                )}
              </>
            )}

            {step === 4 && (
              <>
                <div className="booking-section-title">
                  <span>PASO 4</span>
                  <h2>Datos de contacto</h2>
                  <p>Los utilizaremos para enviarte la confirmación.</p>
                </div>

                <div className="form-grid">
                  <label>
                    Nombre y apellidos *
                    <input
                      name="name"
                      value={customer.name}
                      onChange={updateCustomer}
                      placeholder="Ej. María García"
                    />
                  </label>
                  <label>
                    Correo electrónico *
                    <input
                      name="email"
                      type="email"
                      value={customer.email}
                      onChange={updateCustomer}
                      placeholder="nombre@correo.com"
                    />
                  </label>
                  <label>
                    Teléfono *
                    <input
                      name="phone"
                      value={customer.phone}
                      onChange={updateCustomer}
                      placeholder="+34 600 000 000"
                    />
                  </label>
                  <label>
                    Ciudad
                    <input
                      name="city"
                      value={customer.city}
                      onChange={updateCustomer}
                      placeholder="Ej. Sevilla"
                    />
                  </label>
                  <label className="full">
                    Observaciones
                    <textarea
                      name="notes"
                      value={customer.notes}
                      onChange={updateCustomer}
                      placeholder="Necesidades de accesibilidad, información del grupo..."
                    />
                  </label>
                </div>

                <label className="privacy-check">
                  <input
                    type="checkbox"
                    name="privacy"
                    checked={customer.privacy}
                    onChange={updateCustomer}
                  />
                  <span>
                    Acepto la política de privacidad y el tratamiento de mis datos
                    para gestionar esta reserva.
                  </span>
                </label>
              </>
            )}

            {step === 5 && (
              <div className="confirmation">
                <div className="confirmation-icon">✓</div>
                <p className="booking-kicker">RESERVA PREPARADA</p>
                <h2>Gracias, {customer.name.split(" ")[0] || "viajero"}</h2>
                <p>
                  Esta versión del Sprint 2 todavía no envía datos a una base de
                  datos. La navegación y el resumen ya están preparados para la
                  siguiente fase.
                </p>
                <div className="confirmation-code">
                  <small>Referencia de prueba</small>
                  <strong>ET-{Date.now().toString().slice(-6)}</strong>
                </div>
                <button
                  className="primary-button"
                  onClick={() => {
                    setStep(1);
                    setSelectedDate("");
                    setCustomer({
                      name: "",
                      email: "",
                      phone: "",
                      city: "",
                      notes: "",
                      privacy: false,
                    });
                  }}
                >
                  Crear otra reserva
                </button>
              </div>
            )}

            {step < 5 && (
              <footer className="booking-actions">
                {step > 1 ? (
                  <button className="back-button" onClick={back}>
                    ← Volver
                  </button>
                ) : (
                  <button
                    className="back-button"
                    onClick={() => (window.location.hash = "/")}
                  >
                    ← Panel
                  </button>
                )}
                <button
                  className="primary-button"
                  disabled={!canContinue()}
                  onClick={next}
                >
                  {step === 4 ? "Confirmar reserva" : "Continuar"} →
                </button>
              </footer>
            )}
          </section>

          <aside className="booking-card booking-summary">
            <p className="booking-kicker">TU RESERVA</p>
            <h3>{product.name}</h3>
            <p>{product.eyebrow}</p>

            <dl>
              <div>
                <dt>Duración</dt>
                <dd>{product.duration}</dd>
              </div>
              <div>
                <dt>Punto de encuentro</dt>
                <dd>{product.meetingPoint}</dd>
              </div>
              <div>
                <dt>Fecha</dt>
                <dd>
                  {dateOption
                    ? `${formatDate(dateOption.date)} · ${dateOption.time} h`
                    : productId === "privada"
                    ? "A convenir"
                    : "Pendiente"}
                </dd>
              </div>
              <div>
                <dt>Personas</dt>
                <dd>
                  {adults} adulto{adults !== 1 ? "s" : ""}
                  {children > 0 ? ` · ${children} niño${children !== 1 ? "s" : ""}` : ""}
                  {babies > 0 ? ` · ${babies} bebé${babies !== 1 ? "s" : ""}` : ""}
                </dd>
              </div>
            </dl>

            <div className="summary-total">
              <span>Total</span>
              <strong>{total === null ? "A consultar" : formatPrice(total)}</strong>
            </div>

            <small className="summary-payment">
              Pago presencial. No se realizará ningún cargo online.
            </small>
          </aside>
        </div>
      </main>
    </div>
  );
}

function Counter({ label, detail, value, min, onChange }) {
  return (
    <div className="people-row">
      <span>
        <strong>{label}</strong>
        <small>{detail}</small>
      </span>
      <div className="counter">
        <button
          type="button"
          disabled={value <= min}
          onClick={() => onChange(Math.max(min, value - 1))}
        >
          −
        </button>
        <strong>{value}</strong>
        <button type="button" onClick={() => onChange(value + 1)}>
          +
        </button>
      </div>
    </div>
  );
}
