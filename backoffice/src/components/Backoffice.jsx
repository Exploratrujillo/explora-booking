import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { endExclusiveForView } from '../lib/dates'
import { CalendarToolbar } from './CalendarToolbar'
import { MonthView } from './MonthView'
import { ListView } from './ListView'
import { CreateDepartureModal } from './CreateDepartureModal'
import { DepartureModal } from './DepartureModal'
import { ScheduleBlockModal } from './ScheduleBlockModal'
import { BlockManager } from './BlockManager'
import { AgendaDashboard } from './AgendaDashboard'
import { OperationsDashboard } from './OperationsDashboard'
import './BlockManager.css'

function Icon({ name, size = 20 }) {
  const paths = {
    agenda: <><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 10h18"/><path d="M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01"/></>,
    operations: <><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 9h18"/><path d="M7 13h4M7 17h7"/></>,
    blocks: <><rect x="3" y="4" width="18" height="17" rx="2"/><path d="M8 2v4M16 2v4M3 9h18"/><path d="m9 15 2 2 4-5"/></>,
    reservations: <><path d="M4 4h16v16H4z"/><path d="M8 8h8M8 12h8M8 16h5"/></>,
    clients: <><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></>,
    checkin: <><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></>,
    logout: <><path d="M10 17l5-5-5-5"/><path d="M15 12H3"/><path d="M21 19V5a2 2 0 0 0-2-2h-6"/></>,
  }

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  )
}

export function Backoffice({ profile }) {
  const [section, setSection] = useState('agenda')
  const [anchor, setAnchor] = useState(new Date())
  const [view, setView] = useState('month')
  const [departures, setDepartures] = useState([])
  const [experiences, setExperiences] = useState([])
  const [guides, setGuides] = useState([])
  const [experienceId, setExperienceId] = useState('')
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')
  const [creating, setCreating] = useState(false)
  const [planning, setPlanning] = useState(false)
  const [selected, setSelected] = useState(null)
  const [blocksRefreshKey, setBlocksRefreshKey] = useState(0)

  const range = useMemo(
    () => endExclusiveForView(anchor, view),
    [anchor, view]
  )

  const loadCatalogues = useCallback(async () => {
    const [experiencesResult, guidesResult] = await Promise.all([
      supabase.rpc('list_backoffice_experiences'),
      supabase.rpc('list_active_guides'),
    ])

    if (experiencesResult.error || guidesResult.error) {
      setMessage(
        experiencesResult.error?.message ||
        guidesResult.error?.message ||
        'No se pudieron cargar los catálogos.'
      )
      return
    }

    const catalogue = experiencesResult.data || []
    setExperiences(catalogue)
    setGuides(guidesResult.data || [])
    setExperienceId((current) => current || catalogue[0]?.id || '')
  }, [])

  const loadDepartures = useCallback(async () => {
    if (section === 'blocks') {
      setLoading(false)
      return
    }

    setLoading(true)
    setMessage('')

    const rpcName = section === 'agenda'
      ? 'list_agenda_departures'
      : 'list_operational_departures'

    const params = {
      p_from: range.start.toISOString(),
      p_until: range.end.toISOString(),
    }

    if (section === 'operations') {
      params.p_experience_id = experienceId || null
    }

    const { data, error } = await supabase.rpc(rpcName, params)

    if (error) {
      setMessage(error.message)
    } else {
      setDepartures(data || [])
      setSelected((current) => {
        if (!current) return null
        return (data || []).find((item) => item.id === current.id) || null
      })
    }

    setLoading(false)
  }, [section, experienceId, range.start.getTime(), range.end.getTime()])

  useEffect(() => {
    loadCatalogues()
  }, [loadCatalogues])

  useEffect(() => {
    loadDepartures()
  }, [loadDepartures])

  async function signOut() {
    await supabase.auth.signOut()
  }

  function handleBlockGenerated() {
    loadDepartures()
    setBlocksRefreshKey((current) => current + 1)
  }

  const sectionCopy = {
    agenda: {
      eyebrow: 'OPERACIÓN DIARIA',
      title: 'Agenda',
      description: 'Consulta las salidas con reservas y la actividad operativa del día.',
    },
    operations: {
      eyebrow: 'PLANIFICACIÓN COMERCIAL',
      title: 'Operativa por producto',
      description: 'Gestiona las salidas programadas de cada experiencia.',
    },
    blocks: {
      eyebrow: 'PLANIFICACIÓN COMERCIAL',
      title: 'Gestor de bloques',
      description: 'Crea, revisa y mantiene la planificación recurrente de las experiencias.',
    },
  }

  const copy = sectionCopy[section]

  const navItems = [
    ['agenda', 'agenda', 'Agenda'],
    ['operations', 'operations', 'Operativa por producto'],
    ['blocks', 'blocks', 'Gestor de bloques'],
  ]

  return (
    <main className="app-shell premium-shell">
      <aside className="sidebar premium-sidebar">
        <div className="sidebar-top">
          <div className="premium-brand">
            <div className="premium-brand-symbol">ET</div>
            <div>
              <p className="premium-brand-name">EXPLORA</p>
              <p className="premium-brand-city">TRUJILLO</p>
              <span className="premium-brand-subtitle">Backoffice</span>
            </div>
          </div>

          <nav className="premium-nav">
            {navItems.map(([value, icon, label]) => (
              <button
                key={value}
                className={`nav-item premium-nav-item ${section === value ? 'active' : ''}`}
                onClick={() => setSection(value)}
              >
                <Icon name={icon} />
                <span>{label}</span>
              </button>
            ))}

            <div className="premium-nav-divider" />

            <button className="nav-item premium-nav-item" disabled>
              <Icon name="reservations" />
              <span>Reservas</span>
            </button>
            <button className="nav-item premium-nav-item" disabled>
              <Icon name="clients" />
              <span>Clientes</span>
            </button>
            <button className="nav-item premium-nav-item" disabled>
              <Icon name="checkin" />
              <span>Check-in</span>
            </button>
          </nav>
        </div>

        <div className="sidebar-user premium-sidebar-user">
          <div className="premium-user-row">
            <div className="premium-avatar">
              {(profile.display_name || profile.full_name || 'E').slice(0, 1).toUpperCase()}
            </div>
            <div>
              <strong>{profile.display_name || profile.full_name}</strong>
              <span>Guía oficial</span>
              <small><i /> Conectada</small>
            </div>
          </div>

          <button className="premium-logout" onClick={signOut}>
            <Icon name="logout" size={18} />
            <span>Cerrar sesión</span>
          </button>
        </div>
      </aside>

      <section className="main-panel premium-main-panel v2-main-panel">
        <div className="v2-topbar">
          <div><span>Explora Booking</span><b>/</b><strong>{section === 'agenda' ? 'Agenda' : section === 'operations' ? 'Operativa' : 'Gestor de bloques'}</strong></div>
          <div className="v2-top-actions"><button aria-label="Buscar">⌕</button><button aria-label="Notificaciones">♢</button><span><i /> Sistema operativo</span></div>
        </div>

        {section === 'agenda' && (
          <AgendaDashboard
            anchor={anchor}
            setAnchor={setAnchor}
            view={view}
            setView={setView}
            departures={departures}
            loading={loading}
            onOpen={setSelected}
          />
        )}

        {section === 'operations' && (
          <OperationsDashboard
            anchor={anchor}
            setAnchor={setAnchor}
            view={view}
            setView={setView}
            departures={departures}
            loading={loading}
            experiences={experiences}
            experienceId={experienceId}
            setExperienceId={setExperienceId}
            onCreate={() => setCreating(true)}
            onPlan={() => setPlanning(true)}
            onOpen={setSelected}
          />
        )}

        {section === 'blocks' && (
          <div className="v2-blocks-page">
            <section className="v2-hero-row compact">
              <div><p className="v2-kicker">PLANIFICACIÓN COMERCIAL</p><h1>Gestor de bloques</h1><p>Crea, revisa y mantiene la planificación recurrente de las experiencias.</p></div>
            </section>
            <BlockManager
              experiences={experiences}
              guides={guides}
              refreshKey={blocksRefreshKey}
              onCreateBlock={(selectedExperienceId) => {
                setExperienceId(selectedExperienceId || experiences[0]?.id || '')
                setPlanning(true)
              }}
              onOpenCalendar={(selectedExperienceId) => {
                setExperienceId(selectedExperienceId)
                setSection('operations')
              }}
            />
          </div>
        )}
      </section>

      <ScheduleBlockModal
        open={planning}
        onClose={() => setPlanning(false)}
        experiences={experiences}
        guides={guides}
        defaultExperienceId={experienceId}
        anchor={anchor}
        onGenerated={handleBlockGenerated}
      />

      <CreateDepartureModal
        open={creating}
        onClose={() => setCreating(false)}
        experiences={experiences}
        guides={guides}
        anchor={anchor}
        onCreated={loadDepartures}
      />

      <DepartureModal
        departure={selected}
        guides={guides}
        onClose={() => setSelected(null)}
        onChanged={loadDepartures}
      />
    </main>
  )
}
