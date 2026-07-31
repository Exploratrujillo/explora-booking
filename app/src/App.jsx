import { useMemo, useState } from "react";
import "./App.css";
import MonthlyCalendar from "./components/MonthlyCalendar";

const EXPERIENCES = [
  { id: "esencial", code: "ETES", name: "Trujillo Esencial", priceAdult: 9.5, childMode: "0-11-free", duration: "2 horas", meeting: "Plaza Mayor", hours: ["10:30", "17:30"] },
  { id: "candil", code: "ETNC", name: "A la luz del Candil", priceAdult: 10, childMode: "12plus", duration: "1 h 45 min", meeting: "Plaza Mayor", hours: ["21:30"] },
  { id: "exploradores", code: "ETPE", name: "Pequeños Exploradores", priceAdult: 10, childMode: "0-3-free-4-14-paid", duration: "2 horas", meeting: "Plaza Mayor", hours: ["11:00", "17:00"] },
  { id: "privada", code: "ETPV", name: "Visita Privada", priceAdult: null, childMode: "custom", duration: "A convenir", meeting: "A convenir", hours: ["Consultar"] },
];

const PROVINCES = ["Álava", "Albacete", "Alicante", "Almería", "Asturias", "Ávila", "Badajoz", "Barcelona", "Bizkaia", "Burgos", "Cáceres", "Cádiz", "Cantabria", "Castellón", "Ciudad Real", "Córdoba", "A Coruña", "Cuenca", "Gipuzkoa", "Girona", "Granada", "Guadalajara", "Huelva", "Huesca", "Illes Balears", "Jaén", "León", "Lleida", "Lugo", "Madrid", "Málaga", "Murcia", "Navarra", "Ourense", "Palencia", "Las Palmas", "Pontevedra", "La Rioja", "Salamanca", "Santa Cruz de Tenerife", "Segovia", "Sevilla", "Soria", "Tarragona", "Teruel", "Toledo", "Valencia", "Valladolid", "Zamora", "Zaragoza", "Ceuta", "Melilla"];

const availability = {};
for (let month = 7; month <= 11; month += 1) {
  const days = new Date(2026, month + 1, 0).getDate();
  for (let day = 1; day <= days; day += 1) {
    const date = `${2026}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
    const weekday = new Date(2026, month, day).getDay();
    availability[date] = weekday === 1 || weekday === 3 || weekday === 5 || weekday === 6 ? "available" : "unavailable";
  }
}

function money(value) {
  if (value === null) return "Consultar";
  return new Intl.NumberFormat("es-ES", { style: "currency", currency: "EUR" }).format(value);
}

function Counter({ label, value, onChange, min = 0, hint }) {
  return <div className="counter-row"><div><b>{label}</b>{hint && <small>{hint}</small>}</div><div className="counter"><button type="button" onClick={() => onChange(Math.max(min, value - 1))}>−</button><span>{value}</span><button type="button" onClick={() => onChange(value + 1)}>+</button></div></div>;
}

export default function App() {
  const [step, setStep] = useState(1);
  const [experienceId, setExperienceId] = useState("esencial");
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [adults, setAdults] = useState(2);
  const [childAges, setChildAges] = useState([]);
  const [customer, setCustomer] = useState({ firstName: "", lastName: "", email: "", phone: "", country: "España", region: "", source: "" });
  const [confirmed, setConfirmed] = useState(false);

  const experience = EXPERIENCES.find((item) => item.id === experienceId);
  const paidChildren = experience.childMode === "0-3-free-4-14-paid" ? childAges.filter((age) => age >= 4 && age <= 14).length : 0;
  const total = experience.priceAdult === null ? null : adults * experience.priceAdult + paidChildren * 6;
  const locator = `${experience.code}-000124`;

  const canContinue = useMemo(() => {
    if (step === 2) return Boolean(date && time);
    if (step === 3) return adults > 0;
    if (step === 4) return Boolean(customer.firstName && customer.lastName && customer.email && customer.phone && customer.country && customer.region);
    return true;
  }, [step, date, time, adults, customer]);

  function selectExperience(id) {
    setExperienceId(id); setDate(""); setTime(""); setChildAges([]); setStep(2);
  }

  function addChild() {
    setChildAges((ages) => [...ages, 0]);
  }

  function removeChild(index) {
    setChildAges((ages) => ages.filter((_, i) => i !== index));
  }

  function updateChild(index, age) {
    setChildAges((ages) => ages.map((value, i) => i === index ? Number(age) : value));
  }

  function finishBooking() {
    setConfirmed(true);
    setStep(5);
  }

  function downloadVoucher() {
    const text = `EXPLORA TRUJILLO\nBONO DE RESERVA\n\nLocalizador: ${locator}\nExperiencia: ${experience.name}\nFecha: ${date}\nHora: ${time}\nAdultos: ${adults}\nNiños: ${childAges.length}\nImporte: ${money(total)}\nPago presencial\nPunto de encuentro: ${experience.meeting}`;
    const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url; anchor.download = `${locator}-bono.txt`; anchor.click();
    URL.revokeObjectURL(url);
  }

  function addCalendar() {
    const start = `${date.replaceAll("-", "")}T${time.replace(":", "")}00`;
    const ics = `BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nDTSTART:${start}\nSUMMARY:${experience.name}\nLOCATION:${experience.meeting}\nDESCRIPTION:Reserva ${locator} - Explora Trujillo\nEND:VEVENT\nEND:VCALENDAR`;
    const blob = new Blob([ics], { type: "text/calendar;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a"); anchor.href = url; anchor.download = `${locator}.ics`; anchor.click(); URL.revokeObjectURL(url);
  }

  return <div className="booking-page">
    <header className="brand-header"><div><span className="brand-mark">⌂</span><div><strong>EXPLORA</strong><small>TRUJILLO</small></div></div><p>Reserva oficial · Pago presencial</p></header>

    <main className="booking-shell">
      <section className="booking-card">
        <div className="progress">
          {["Experiencia", "Fecha y hora", "Personas", "Tus datos", "Confirmación"].map((label, index) => <div key={label} className={step >= index + 1 ? "active" : ""}><span>{index + 1}</span><small>{label}</small></div>)}
        </div>

        {step === 1 && <div className="step-content"><h1>Elige tu experiencia</h1><p className="lead">Selecciona la visita que deseas reservar.</p><div className="experience-grid">{EXPERIENCES.map((item) => <button type="button" className={`experience-card ${experienceId === item.id ? "selected" : ""}`} key={item.id} onClick={() => selectExperience(item.id)}><h2>{item.name}</h2><p>{item.duration}</p><strong>{item.priceAdult === null ? "Consultar" : `Desde ${money(item.priceAdult)}`}</strong></button>)}</div></div>}

        {step === 2 && <div className="step-content compact-step"><h1>Selecciona fecha y hora</h1><div className="date-time-layout"><MonthlyCalendar selectedDate={date} onSelectDate={(value) => { setDate(value); setTime(""); }} availability={availability} /><div className="time-panel"><h3>Hora de salida</h3>{date ? <div className="time-options">{experience.hours.map((hour) => <button type="button" key={hour} className={time === hour ? "selected" : ""} onClick={() => setTime(hour)}>{hour}</button>)}</div> : <p>Selecciona primero un día disponible.</p>}<div className="selection-note"><b>{experience.name}</b><small>{date || "Fecha pendiente"}{time ? ` · ${time}` : ""}</small></div></div></div></div>}

        {step === 3 && <div className="step-content"><h1>¿Cuántas personas sois?</h1><div className="people-box"><Counter label="Adultos" value={adults} min={1} onChange={setAdults} hint={experience.id === "esencial" ? "12 años o más" : experience.id === "exploradores" ? "15 años o más" : "Participantes"} />
          {experience.childMode !== "12plus" && experience.childMode !== "custom" && <div className="children-section"><div className="children-title"><div><b>Niños</b><small>{experience.id === "esencial" ? "0 a 11 años · GRATIS" : "0–3 GRATIS · 4–14 años: 6 €"}</small></div><button type="button" onClick={addChild}>+ Añadir niño</button></div>{childAges.map((age, index) => <div className="child-row" key={index}><label>Niño {index + 1}<select value={age} onChange={(e) => updateChild(index, e.target.value)}>{Array.from({ length: experience.id === "esencial" ? 12 : 15 }, (_, n) => <option value={n} key={n}>{n} años{experience.id === "esencial" || n <= 3 ? " · GRATIS" : ""}</option>)}</select></label><button type="button" className="remove" onClick={() => removeChild(index)}>Eliminar</button></div>)}</div>}
          {experience.childMode === "12plus" && <div className="info-banner">Esta experiencia está dirigida a adultos y participantes de 12 años o más.</div>}
        </div></div>}

        {step === 4 && <div className="step-content"><h1>Tus datos</h1><form className="form-grid" autoComplete="on" onSubmit={(event) => event.preventDefault()}><label htmlFor="given-name">Nombre *<input id="given-name" name="given-name" autoComplete="given-name" value={customer.firstName} onChange={(e) => setCustomer({ ...customer, firstName: e.target.value })} /></label><label htmlFor="family-name">Apellidos *<input id="family-name" name="family-name" autoComplete="family-name" value={customer.lastName} onChange={(e) => setCustomer({ ...customer, lastName: e.target.value })} /></label><label htmlFor="email">Correo electrónico *<input id="email" name="email" type="email" autoComplete="email" value={customer.email} onChange={(e) => setCustomer({ ...customer, email: e.target.value })} /></label><label htmlFor="tel">Teléfono móvil *<input id="tel" name="tel" type="tel" inputMode="tel" autoComplete="tel" placeholder="Ej. 644 659 449" value={customer.phone} onChange={(e) => setCustomer({ ...customer, phone: e.target.value })} /></label><label htmlFor="country">País *<select id="country" name="country" autoComplete="country-name" value={customer.country} onChange={(e) => setCustomer({ ...customer, country: e.target.value, region: "" })}><option>España</option><option>Portugal</option><option>Francia</option><option>Reino Unido</option><option>Alemania</option><option>Estados Unidos</option><option>Otro</option></select></label><label htmlFor="region">{customer.country === "España" ? "Provincia *" : "Región / Estado *"}{customer.country === "España" ? <select id="region" name="address-level2" autoComplete="address-level2" value={customer.region} onChange={(e) => setCustomer({ ...customer, region: e.target.value })}><option value="">Selecciona una provincia</option>{PROVINCES.map((province) => <option key={province}>{province}</option>)}</select> : <input id="region" name="address-level1" autoComplete="address-level1" value={customer.region} onChange={(e) => setCustomer({ ...customer, region: e.target.value })} />}</label><label className="full" htmlFor="source">¿Cómo nos has conocido?<select id="source" name="booking-source" autoComplete="off" value={customer.source} onChange={(e) => setCustomer({ ...customer, source: e.target.value })}><option value="">Selecciona una opción</option><option>Google</option><option>Google Maps</option><option>Recomendación de amigos o familiares</option><option>Hotel</option><option>Oficina de Turismo</option><option>GetYourGuide</option><option>Redes sociales</option><option>Ya había venido antes</option><option>Otro</option></select></label></form></div>}

        {step === 5 && confirmed && <div className="confirmation"><div className="success-icon">✓</div><h1>Reserva confirmada</h1><p>Guarda esta pantalla o descarga tu bono.</p><div className="locator"><small>LOCALIZADOR</small><strong>{locator}</strong></div><div className="confirmation-data"><b>{experience.name}</b><span>{date} · {time}</span><span>{adults} adulto{adults !== 1 ? "s" : ""}{childAges.length ? ` · ${childAges.length} niño${childAges.length !== 1 ? "s" : ""}` : ""}</span><span>{money(total)} · Pago presencial</span><span>{experience.meeting}</span></div><div className="confirmation-actions"><button type="button" className="primary" onClick={downloadVoucher}>Descargar bono</button><button type="button" onClick={addCalendar}>Añadir al calendario</button><button type="button" onClick={() => alert("Aquí se permitirá corregir el email y reenviar la confirmación.")}>Reenviar por email</button></div></div>}

        {step < 5 && <div className="footer-actions"><button type="button" className="ghost" onClick={() => setStep(Math.max(1, step - 1))} disabled={step === 1}>Volver</button><button type="button" className="primary" disabled={!canContinue} onClick={() => step === 4 ? finishBooking() : setStep(step + 1)}>{step === 4 ? "Confirmar reserva" : "Continuar"}</button></div>}
      </section>

      {step < 5 && <aside className="summary-card"><span className="eyebrow">RESUMEN</span><h2>{experience.name}</h2><dl><div><dt>Fecha</dt><dd>{date || "Pendiente"}</dd></div><div><dt>Hora</dt><dd>{time || "Pendiente"}</dd></div><div><dt>Adultos</dt><dd>{adults}</dd></div>{childAges.length > 0 && <div><dt>Niños</dt><dd>{childAges.map((age) => `${age} años`).join(", ")}</dd></div>}<div><dt>Punto de encuentro</dt><dd>{experience.meeting}</dd></div></dl><div className="summary-total"><span>Total</span><strong>{money(total)}</strong></div><small>El pago se realizará presencialmente.</small></aside>}
    </main>
  </div>;
}
