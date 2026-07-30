
import { useState } from "react";
import "./App.css";
import foto from "./assets/esmeralda.jpg";

const menu = ["⌂ Inicio","▣ Calendario","🎟 Reservas","♙ Clientes","⚑ Experiencias","🤝 Colaboradores","⌖ Destino","▥ Negocio","⚙ Configuración"];

export default function App(){
  const [open,setOpen]=useState(false);
  const [msg,setMsg]=useState("");

  const action=(text)=>{
    setOpen(false);
    setMsg(`${text}: se conectará en el siguiente sprint.`);
    setTimeout(()=>setMsg(""),3000);
  };

  return <div className="app">
    <aside className="sidebar">
      <div className="brand">
        <div className="arch">⌒</div>
        <div className="brand-main">EXPLORA</div>
        <div className="brand-sub">TRUJILLO</div>
        <small>Historia que te recibe</small>
      </div>
      <nav>{menu.map((item,i)=><button className={i===0?"active":""} key={item}>{item}</button>)}</nav>
      <button className="guide">☀ <span><b>MODO GUÍA</b><small>Activar para tus visitas</small></span></button>
      <div className="profile">
        <img src={foto} alt="Esmeralda Gamino"/>
        <div><b>Esmeralda Gamino</b><small>Guía Oficial GT-202</small><em>● Disponible</em></div>
      </div>
    </aside>

    <main>
      <header>
        <div className="search">⌕ <input placeholder="Buscar reservas, clientes, experiencias..."/></div>
        <div className="actions">
          <div className="reserve-wrap">
            <button className="reserve" onClick={()=>setOpen(!open)}>＋ Reservar⌄</button>
            {open && <div className="dropdown">
              <button onClick={()=>action("Nueva reserva")}><b>＋ Nueva reserva</b><small>Crear una nueva reserva</small></button>
              <button onClick={()=>action("Bloquear fecha")}><b>▣ Bloquear fecha</b><small>Visita privada o grupo</small></button>
            </div>}
          </div>
          <button className="round">💬</button>
          <button className="round">🔔<i>3</i></button>
          <div className="clock"><small>miércoles, 29 de julio</small><b>09:15</b></div>
        </div>
      </header>

      <section className="content">
        {msg && <div className="toast">{msg}</div>}
        <div className="welcome">
          <div><h1>¡Buenos días, Esmeralda! ☀</h1><p>Todo listo para seguir compartiendo Trujillo.</p></div>
          <div className="ok">✓ <span><b>Todo al día</b><small>No tienes incidencias críticas</small></span></div>
        </div>

        <div className="grid">
          <article className="card next">
            <h3>PRÓXIMA SALIDA</h3>
            <div className="next-body">
              <div className="tour-photo"><span>A PIE</span><div className="city">▥▥▥</div></div>
              <div className="tour-info">
                <small className="green">✓ Salida garantizada</small>
                <h2>Trujillo Esencial</h2>
                <p>◷ <b>10:30</b> · 2 h</p>
                <p>⌖ Plaza Mayor</p>
                <p>♙ 12 / 20 personas</p>
                <div className="progress"><i></i></div>
                <small className="occupancy">60 % de ocupación</small>
                <div className="guaranteed">✓ <span><b>Visita garantizada</b><small>Mínimo alcanzado (4 adultos)</small></span></div>
              </div>
            </div>
            <div className="tour-footer">
              <div><small>Guía</small><b>Esmeralda Gamino</b></div>
              <div><small>Idioma</small><b>Español</b></div>
              <div><small>Punto de encuentro</small><b>Plaza Mayor</b></div>
              <button onClick={()=>action("Entrar en la salida")}>Entrar en la salida →</button>
            </div>
          </article>

          <article className="card agenda">
            <div className="card-head"><h3>TU JORNADA</h3><a>Ver agenda completa</a></div>
            {[
              ["✓","09:00","Preparar listado de asistentes","Completado","done"],
              ["◷","09:15","Confirmar WhatsApp","Familia López","pending"],
              ["✓","09:30","Visita garantizada","Mínimo alcanzado","done"],
              ["·","11:45","Envío de entradas","Pendiente","neutral"]
            ].map(x=><div className="task" key={x[1]}>
              <i className={x[4]}>{x[0]}</i><time>{x[1]}</time><span><b>{x[2]}</b><small>{x[3]}</small></span>
            </div>)}
            <button className="link">Ver todas las tareas (6) →</button>
          </article>

          <article className="card calendar">
            <h3>HOY EN TU CALENDARIO</h3>
            <div className="timeline">
              <div><time>09:00</time><i></i><span></span></div>
              <div><time>10:30</time><i></i><span className="event green-bg"><b>Trujillo Esencial</b><small>12 / 20</small></span></div>
              <div><time>12:00</time><i></i><span>Tiempo libre / Gestión</span></div>
              <div><time>17:30</time><i></i><span className="event gold-bg"><b>A la luz del Candil</b><small>6 / 20</small></span></div>
              <div><time>20:30</time><i></i><span>Cena con grupo privado</span></div>
            </div>
            <button className="secondary">▣ Ver calendario completo</button>
          </article>

          <article className="card recent">
            <div className="card-head"><h3>RESERVAS RECIENTES</h3><a>Ver todas</a></div>
            {[
              ["FG","Familia García","Trujillo Esencial · 4 personas","Hoy · 09:05"],
              ["ML","María López","Pequeños Exploradores · 3 personas","Ayer · 18:47"],
              ["CS","Grupo Colegio San José","Trujillo Esencial · 20 personas","Ayer · 16:22"]
            ].map(r=><div className="row" key={r[1]}><i>{r[0]}</i><span><b>{r[1]}</b><small>{r[2]}</small></span><time>{r[3]}</time><em></em></div>)}
            <button className="secondary">🎟 Ver todas las reservas</button>
          </article>

          <article className="card messages">
            <div className="card-head"><h3>MENSAJES</h3><a>Ver todos</a></div>
            <div className="message"><img src={foto}/><span><b>Familia López</b><small>Confirmación de la visita</small></span><time>09:10</time><em>1</em></div>
            <div className="message"><i>HI</i><span><b>Hotel Izan</b><small>Petición de disponibilidad</small></span><time>08:55</time></div>
            <div className="message"><i>GYG</i><span><b>GetYourGuide</b><small>Nueva reserva recibida</small></span><time>08:42</time></div>
            <button className="secondary">💬 Ir a mensajes</button>
          </article>
        </div>
      </section>
    </main>
  </div>
}
