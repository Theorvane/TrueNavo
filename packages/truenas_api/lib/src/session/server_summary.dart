final class ServerSummary {
  const ServerSummary({
    required this.originalHostInput,
    required this.endpointUri,
    required this.identity,
    required this.version,
    required this.availableMethodNames,
  });
  final String originalHostInput;
  final Uri endpointUri;
  final String identity;
  final String version;
  final Set<String> availableMethodNames;
}
