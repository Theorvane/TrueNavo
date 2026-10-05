enum TrueNavoDensity {
  comfortable(rowHeight: 56, controlHeight: 48, groupGap: 24),
  standard(rowHeight: 52, controlHeight: 44, groupGap: 20),
  compact(rowHeight: 44, controlHeight: 40, groupGap: 16);

  const TrueNavoDensity({
    required this.rowHeight,
    required this.controlHeight,
    required this.groupGap,
  });
  final double rowHeight;
  final double controlHeight;
  final double groupGap;

  static TrueNavoDensity resolve(double width) => width < 600
      ? comfortable
      : width < 1000
      ? standard
      : compact;
}
