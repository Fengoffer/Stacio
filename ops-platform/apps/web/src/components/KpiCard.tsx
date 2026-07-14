interface KpiCardProps {
  label: string;
  value: string | number;
  detail: string;
  tone?: "blue" | "green" | "orange" | "red";
}

export function KpiCard({ label, value, detail, tone = "blue" }: KpiCardProps) {
  return (
    <section className={`kpi-card kpi-card-${tone}`}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      <div className="kpi-detail">{detail}</div>
    </section>
  );
}
