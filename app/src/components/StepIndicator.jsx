export default function StepIndicator({ currentStep }) {
  const steps = ["Experiencia", "Fecha", "Personas", "Datos", "Confirmación"];

  return (
    <div className="step-indicator" aria-label="Progreso de la reserva">
      {steps.map((step, index) => {
        const number = index + 1;
        const state =
          number < currentStep ? "completed" : number === currentStep ? "active" : "";

        return (
          <div className={`step ${state}`} key={step}>
            <span>{number < currentStep ? "✓" : number}</span>
            <small>{step}</small>
          </div>
        );
      })}
    </div>
  );
}
