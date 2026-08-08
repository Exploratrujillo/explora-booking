import { CalendarToolbar } from './CalendarToolbar'
import { MonthView } from './MonthView'
import { ListView } from './ListView'

function Icon({ name, size = 20 }) {
  const paths = {
    people: <><circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20a6 6 0 0 1 12 0M14 15a5 5 0 0 1 7 4.5"/></>,
    ticket: <><path d="M4 7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-2a2 2 0 0 0 0-4V7Z"/><path d="M9 9h6M9 13h4"/></>,
    alert: <><path d="M12 3 2.8 19h18.4L12 3Z"/><path d="M12 9v4M12 17h.01"/></>,
    clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
    calendar: <><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 9h18"/></>,
    check: <><circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16 9"/></>,
    arrow: <><path d="M5 12h14"/><path d="m15 8 4 4-4 4"/></>,
    pin: <><path d="M20 10c0 5-8 11-8 11S4 15 4 10a8 8 0 1 1 16 0Z"/><circle cx="12" cy="10" r="2.5"/></>,
  }
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

function StatCard({ icon, value, label, caption, tone }) {
  return <article className="px-stat-card"><span className={`px-stat-icon ${tone}`}><Icon name={icon} size={22}/></span><div><strong>{value}</strong><b>{label}</b><small>{caption}</small></div></article>
}

export function AgendaDashboard({ anchor, setAnchor, view, setView, departures, loading, onOpen }) {
  const next = departures[0]
  const people = departures.reduce((sum, item) => sum + Number(item.total_guests || item.booked_guests || 0), 0)
  const startTime = next ? new Date(next.starts_at).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' }) : '10:30'

  return (
    <div className="px-dashboard">
      <section className="px-welcome">
        <div><p className="px-kicker">DOMINGO, 3 DE AGOSTO</p><h1>Buenos días, Esmeralda <span>☀</span></h1><p>Tu jornada está preparada. Aquí tienes lo importante de un vistazo.</p></div>
        <div className="px-health"><span><Icon name="check" size={17}/></span><div><strong>Todo al día</strong><small>No tienes incidencias críticas</small></div></div>
      </section>

      <section className="px-stats">
        <StatCard icon="people" value={departures.length} label="VISITAS HOY" caption={`${people} personas previstas`} tone="green"/>
        <StatCard icon="ticket" value={departures.length} label="RESERVAS ACTIVAS" caption="Online y presenciales" tone="green"/>
        <StatCard icon="alert" value="0" label="PENDIENTES" caption="Nada requiere atención" tone="gold"/>
        <StatCard icon="clock" value="4 min" label="TIEMPO ESTIMADO" caption="Para dejar todo listo" tone="violet"/>
      </section>

      <section className="px-focus-grid">
        <article className="px-feature-card">
          <header><span>PRÓXIMA SALIDA</span>{next && <button onClick={() => onOpen(next)}>Ver salida <Icon name="arrow" size={16}/></button>}</header>
          <div className="px-feature-body">
            <div className="px-city-art" aria-hidden="true"><span className="px-sun"/><span className="px-tower one"/><span className="px-tower two"/><span className="px-church"/><span className="px-ground"/></div>
            <div className="px-feature-copy">
              <span className="px-pill">A PIE</span>
              <h2>{next?.experience_name || 'Trujillo Esencial'}</h2>
              <div className="px-feature-line"><Icon name="clock" size={18}/><strong>{startTime}</strong><i/> <span>2 h</span></div>
              <div className="px-feature-line"><Icon name="pin" size={18}/><span>Plaza Mayor</span></div>
              <div className="px-capacity"><Icon name="people" size={18}/><span>{people || 0} / 20 personas</span></div>
              <div className="px-guarantee"><Icon name="check" size={18}/><div><strong>{next ? 'Salida programada' : 'Sin reservas todavía'}</strong><small>{next ? 'Preparada para recibir al grupo' : 'Aparecerá aquí al recibir la primera reserva'}</small></div></div>
            </div>
          </div>
          <footer><span><Icon name="people" size={17}/> Guía <b>{next?.guide_name || 'Esmeralda'}</b></span><span><Icon name="pin" size={17}/> Punto de encuentro <b>Plaza Mayor</b></span></footer>
        </article>

        <div className="px-side-stack">
          <article className="px-task-card">
            <header><span>TU JORNADA</span><button>Ver todas</button></header>
            <div className="px-task done"><span><Icon name="check" size={16}/></span><time>09:00</time><div><strong>Preparar listado de asistentes</strong><small>Completado</small></div></div>
            <div className="px-task pending"><span><Icon name="clock" size={16}/></span><time>09:15</time><div><strong>Confirmar WhatsApp</strong><small>Seguimiento de clientes</small></div></div>
            <div className="px-task done"><span><Icon name="check" size={16}/></span><time>09:30</time><div><strong>Revisar salida garantizada</strong><small>Mínimo alcanzado</small></div></div>
          </article>
          <article className="px-note-card"><div><span>NOTA RÁPIDA</span><button>Editar</button></div><p>Recuerda revisar el punto de encuentro y confirmar los grupos privados de mañana.</p></article>
        </div>
      </section>

      <section className="px-calendar-card">
        <CalendarToolbar anchor={anchor} setAnchor={setAnchor} view={view} setView={setView}/>
        {loading ? <div className="loading-card">Cargando agenda…</div> : departures.length === 0 ? <div className="px-empty-calendar"><span><Icon name="calendar" size={30}/></span><strong>No hay actividad en este periodo</strong><p>Las salidas con reservas aparecerán automáticamente.</p></div> : view === 'month' ? <MonthView anchor={anchor} departures={departures} onOpen={onOpen}/> : <ListView anchor={anchor} view={view} departures={departures} onOpen={onOpen}/>} 
      </section>
    </div>
  )
}
