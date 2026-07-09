import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final start_longitude = 90.4125;
  final start_latitude = 23.8103;
  final destination_longitude = 90.4200;
  final destination_latitude = 23.8200;
  final urlStr = 'http://router.project-osrm.org/route/v1/driving/${start_longitude},${start_latitude};${destination_longitude},${destination_latitude}?overview=full&geometries=polyline';
  final url = Uri.parse(urlStr);
  print('Requesting: ${url}');
  
  final response = await http.get(url);
  print('Status: ${response.statusCode}');
  print('Body: ${response.body}');
}
