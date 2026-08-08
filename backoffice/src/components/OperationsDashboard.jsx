import { CalendarToolbar } from './CalendarToolbar'
import { MonthView } from './MonthView'
import { ListView } from './ListView'

function Icon({ name, size = 20 }) {
  const paths = {
    calendar:<><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 9h18"/></>,
    spark:<><path d="m12 3 1.4 3.6L17 8l-3.6 1.4L12 13l-1.4-3.6L7 8l3.6-1.4L12 3Z"/><path d="m19 14 .8 2.2L22 17l-2.2.8L19 20l-.8-2.2L16 17l2.2-.8L19 14Z"/></>,
    plus:<><path d="M12 5v14M5 12h14"/></>,
    arrow:<><path d="M5 12h14"/><path d="m15 8 4 4-4 4"/></>,
  }
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

export function OperationsDashboard({ anchor, setAnchor, view, setView, departures, loading, experiences, experienceId, setExperienceId, onCreate, onPlan, onOpen }) {
  const selected = experiences.find(item => item.id === experienceId)
  return <div className="px-operations">
    <section className="px-page-head"><div><p className="px-kicker">PLANIFICACIÓN COMERCIAL</p><h1>Operativa por producto</h1><p>Abre, cierra y ajusta las salidas comerciales desde una vista clara.</p></div><label>Experiencia<select value={experienceId} onChange={e=>setExperienceId(e.target.value)}>{experiences.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label></section>
    <section className="px-product-hero"><div className="px-product-orb"><Icon name="spark" size={26}/></div><div><span>EXPERIENCIA SELECCIONADA</span><h2>{selected?.name || 'Experiencia'}</h2><p>Calendario comercial, disponibilidad y salidas extraordinarias.</p></div><div><button className="px-outline" onClick={onCreate}><Icon name="plus" size={17}/> Salida manual</button><button className="px-primary" onClick={onPlan}><Icon name="spark" size={17}/> Generar por bloque</button></div></section>
    <section className="px-calendar-card operations"><CalendarToolbar anchor={anchor} setAnchor={setAnchor} view={view} setView={setView}/>{loading ? <div className="loading-card">Cargando calendario…</div> : departures.length === 0 ? <div className="px-empty-calendar"><span><Icon name="calendar" size={30}/></span><strong>No hay salidas para esta experiencia</strong><p>Crea una salida manual o genera la planificación por bloques.</p><button className="px-inline-action" onClick={onPlan}>Crear planificación <Icon name="arrow" size={16}/></button></div> : view === 'month' ? <MonthView anchor={anchor} departures={departures} onOpen={onOpen}/> : <ListView anchor={anchor} view={view} departures={departures} onOpen={onOpen}/>}</section>
  </div>
}
