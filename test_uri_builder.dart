import 'dart:core';

void main() {
  final url = Uri.https('router.project-osrm.org', '/route/v1/driving/90.41,23.81;90.42,23.82', {'overview': 'full', 'geometries': 'polyline'});
  print(url.toString());
}
