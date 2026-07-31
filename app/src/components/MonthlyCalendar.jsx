import { useMemo, useState } from "react";

const WEEKDAYS = ["LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM"];

function isoDate(year, month, day) {
  return `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

export default function MonthlyCalendar({ selectedDate, onSelectDate, availability }) {
  const initial = selectedDate ? new Date(`${selectedDate}T12:00:00`) : new Date(2026, 7, 1);
  const [cursor, setCursor] = useState(new Date(initial.getFullYear(), initial.getMonth(), 1));

  const cells = useMemo(() => {
    const year = cursor.getFullYear();
    const month = cursor.getMonth();
    const firstDay = new Date(year, month, 1).getDay();
    const mondayOffset = (firstDay + 6) % 7;
    const days = new Date(year, month + 1, 0).getDate();
    return [
      ...Array.from({ length: mondayOffset }, () => null),
      ...Array.from({ length: days }, (_, i) => {
        const day = i + 1;
        const date = isoDate(year, month, day);
        return { day, date, status: availability[date] || "unavailable" };
      }),
    ];
  }, [cursor, availability]);

  const monthTitle = new Intl.DateTimeFormat("es-ES", {
    month: "long",
    year: "numeric",
  })
    .format(cursor)
    .toUpperCase();

  return (
    <section className="monthly-calendar" aria-label="Calendario mensual">
      <div className="calendar-nav">
        <button type="button" aria-label="Mes anterior" onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() - 1, 1))}>‹</button>
        <h3>{monthTitle}</h3>
        <button type="button" aria-label="Mes siguiente" onClick={() => setCursor(new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1))}>›</button>
      </div>

      <div className="weekday-row">
        {WEEKDAYS.map((day) => <span key={day}>{day}</span>)}
      </div>

      <div className="calendar-grid">
        {cells.map((cell, index) => {
          if (!cell) return <span className="calendar-empty" key={`empty-${index}`} />;
          const disabled = cell.status !== "available";
          return (
            <button
              type="button"
              key={cell.date}
              disabled={disabled}
              className={`calendar-day ${cell.status} ${selectedDate === cell.date ? "selected" : ""}`}
              onClick={() => onSelectDate(cell.date)}
              aria-label={`${cell.day}, ${cell.status === "available" ? "disponible" : "completo"}`}
            >
              {cell.day}
            </button>
          );
        })}
      </div>

      <div className="calendar-legend">
        <span><i className="dot available" />Disponible</span>
        <span><i className="dot unavailable" />Completo</span>
      </div>
    </section>
  );
}
