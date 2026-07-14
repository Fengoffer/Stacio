interface StatusBadgeProps {
  children: string;
  tone?: "blue" | "green" | "orange" | "red" | "gray";
}

export function StatusBadge({ children, tone = "gray" }: StatusBadgeProps) {
  return <span className={`status-badge status-badge-${tone}`}>{children}</span>;
}
