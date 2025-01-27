import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart'; // Import go_router
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:async';
import 'firebase_options.dart';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart' show ByteData, Uint8List, rootBundle;
import 'package:flutter/material.dart' show Image, ImageConfiguration;
import 'icon_painter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'map_style.dart';




void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

final GoRouter _router = GoRouter(
  redirect: (BuildContext context ,GoRouterState state) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && state.location == '/') {
      return '/map';
    }
    if (user == null && (state.location == '/map' || state.location == '/requests' || state.location == '/dashboard')) {
      return '/';
    }
    return null; // No redirect
  },
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const AuthPage(),
    ),
     GoRoute(
       path: '/map',
       builder: (context, state) {
           final user = FirebaseAuth.instance.currentUser;
           return MapPage(userName: user?.displayName ?? 'Unkown User',userProfileImage: user?.photoURL ?? '',);
         }
     ),
    GoRoute(
        path: '/requests',
        builder: (context,state) => const RequestPage(),
    ),
    GoRoute(
      path: '/dashboard',
      pageBuilder: (context, state) {
        return CustomTransitionPage(
          key: state.pageKey,
          child: const DashboardPage(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return _slideTransition(animation, secondaryAnimation, child, state);
          },
        );
      },
    ),
  ],
);


Future<String> getDeviceId() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  String? deviceId = prefs.getString('device_id');

  if (deviceId == null) {
    deviceId = Uuid().v4(); // Generate a new UUID
    await prefs.setString('device_id', deviceId); // Store it persistently
  }

  return deviceId;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: _router,
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
    );
  }
}

class AuthPage extends StatelessWidget {
  const AuthPage({super.key});

  Future<User?> signInWithGoogle(BuildContext context) async{
    try{
      final GoogleSignInAccount ? googleUser = await GoogleSignIn().signIn();

      if(googleUser == null){
        return null;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      final OAuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken
      );

      final UserCredential userCredential = await FirebaseAuth.instance.signInWithCredential(credential);

      context.go('/map');

      return userCredential.user;

    }
    catch(e){
      print("Error signing in with Google: $e");
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: const Padding(
          padding:  EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Row(
                children: [
                  Icon(Icons.location_on_rounded, color: Colors.white, size: 35),
                  SizedBox(width: 8),
                  Text(
                    'Place Tracker App',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: Center(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            minimumSize: Size(300, 90),
          ),
          onPressed: () async {
            User? user = await signInWithGoogle(context);
            if (user != null) {
              print("Signed in as: ${user.displayName}");
              // Navigate to the next page or show signed-in info
            } else {
              print("Sign-in failed");
            }
          },
          child: const Text("Sign in with Google",
          style: TextStyle(fontSize: 25),),
        ),
      ),
    );

  }
}


class MapPage extends StatefulWidget {
  final String userName;
  final String userProfileImage;

  const MapPage({super.key,required this.userName,required this.userProfileImage});

  @override
  State<MapPage> createState() => _MapPageState();
}

class MarkerData {
  LatLng position;
  IconData iconData;
  final Color color;

  MarkerData({required this.position, required this.iconData,required this.color});
}


class _MapPageState extends State<MapPage> {
  late GoogleMapController mapController;
  LatLng _initialPosition = const LatLng(0.0, 0.0); // Default center position
  bool _isMapCreated = false;
  bool isNightVision = false;
  Set<String> pressedButtons = {};
  String deviceId = '';
  Timer? _locationUpdateTimer;
  Set<Marker> _markers = {};
  List<String> _profileNames = [];
  List<MarkerData> _markerPositions = [];


  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    fetchProfileNames().then((names){
      setState(() {
        _profileNames = names;
      });
    });
  }

  void _toggleMapStyle() {
    setState(() {
      isNightVision = !isNightVision;
      mapController?.setMapStyle(isNightVision ? nightVisionMapStyle : null);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    getDeviceId().then((id) {
      setState(() {
        deviceId = id;
      });
      _getCurrentLocation();
      _locationUpdateTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
        _getCurrentLocation();
      });
      _fetchOtherDevicesLocations();
    });
  }

  @override
  void dispose() {
    _locationUpdateTimer?.cancel();
    super.dispose();
  }


  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    if (mounted) {
      BitmapDescriptor customIcon = await _getMarkerIcon(widget.userProfileImage);

      setState(() {
        _initialPosition = LatLng(position.latitude, position.longitude);


        _markers.add(Marker(
          markerId: const MarkerId('currentLocation'),
          position: _initialPosition,
          infoWindow: InfoWindow(
            title: 'You are here',
            snippet: widget.userName, // Display user's name below the marker
          ),
            icon: customIcon,
        ));
      });

      if (_isMapCreated) {
        mapController.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: _initialPosition, zoom: 18.0),
          ),
        );
      }

      FirebaseFirestore.instance.collection('Devices').doc(deviceId).set({
        'device_id' : deviceId,
        'latitude' : position.latitude,
        'longitude' : position.longitude,
        'timestamp' : Timestamp.now(),
        'username' : widget.userName,
        'profile_image' : widget.userProfileImage,
      }, SetOptions(merge: true)).then((value){
         print('Location updated');
      }
      ).catchError((error){
        print("Failed to update location: $error");
      });

    }
  }

  Future<void> _fetchOtherDevicesLocations() async {
    User? user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return;
    }

    QuerySnapshot userSnapshot = await FirebaseFirestore.instance
        .collection('Devices')
        .where('username', isEqualTo: user.displayName)
        .get();
    if (userSnapshot.docs.isNotEmpty) {

      List<dynamic> friendList = userSnapshot.docs.first['Friends'] ?? [];

      if(friendList.isEmpty)
        return;

      FirebaseFirestore.instance
          .collection('Devices')
          .where('username' , whereIn: friendList)
          .snapshots()
          .listen((snapshot) async {
        Set<Marker> markers = {};

        for (var doc in snapshot.docs) {
          if (doc['device_id'] != deviceId) {
            double latitude = doc['latitude'];
            double longitude = doc['longitude'];
            String markedId = doc['device_id'];
            String userName = doc['username'];
            String profileImageUrl = doc['profile_image'];
            BitmapDescriptor customIcon = await _getMarkerIcon(profileImageUrl);

            markers.add(Marker(
              markerId: MarkerId(markedId),
              position: LatLng(latitude, longitude),
              infoWindow: InfoWindow(
                title: markedId,
                snippet: userName,
              ),
              icon: customIcon,
            ));
          }
        }

        setState(() {
          for (final newMarker in markers) {
            _markers.removeWhere((marker) =>
            marker.markerId == newMarker.markerId);
            _markers.add(newMarker);
          }
        });
      });
    }
  }

  Future<BitmapDescriptor> _getMarkerIcon(String imageUrl, {double scale = 1.2}) async {
    // Fetch the image from the URL
    final response = await http.get(Uri.parse(imageUrl));

    // Decode the image
    final imageCodec = await ui.instantiateImageCodec(response.bodyBytes);
    final frame = await imageCodec.getNextFrame();
    final image = frame.image;

    // Create a PictureRecorder and Canvas
    final pictureRecorder = ui.PictureRecorder();

    // Increase the canvas size based on the scale factor
    final canvasSize = Size(image.width * scale, image.height * scale);
    final canvas = Canvas(pictureRecorder, Rect.fromPoints(Offset(0, 0), Offset(canvasSize.width, canvasSize.height)));

    final paint = Paint();

    // Define the circle's radius based on the scaled size
    final radius = (canvasSize.width / 2.0);

    // Create a circular clipping path and draw the image on the canvas
    final rect = Rect.fromCircle(center: Offset(radius, radius), radius: radius);
    canvas.clipPath(Path()..addOval(rect));
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect, paint);

    // Convert the image to a PNG format
    final recordedImage = pictureRecorder.endRecording();
    final finalImage = await recordedImage.toImage(canvasSize.width.toInt(), canvasSize.height.toInt());

    final byteData = await finalImage.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    // Return the custom marker as a BitmapDescriptor
    return BitmapDescriptor.fromBytes(bytes);
  }


  void _requestPage(){
    if(mounted){
      context.go('/requests');
    }
  }

  void _gotoDashboard() {
    if (mounted) {
      context.go('/dashboard');
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    mapController = controller;
    _isMapCreated = true;

    if (_initialPosition != const LatLng(0.0, 0.0)) {
      mapController.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _initialPosition, zoom: 15.0),
        ),
      );
    }
  }

  void _toggleButton(String label) async {
    // Check if label is already pressed
    if (pressedButtons.contains(label)) {
      // If pressed, remove markers for that label
      _markers.removeWhere((marker) => marker.infoWindow.title == "$label Marker");
      pressedButtons.remove(label); // Remove label from pressed set
    } else {
      // Otherwise, add markers for that label
      final docSnapshot = await FirebaseFirestore.instance.collection('Devices').doc(deviceId).get();

      if (docSnapshot.exists) {
        final data = docSnapshot.data();

        if (data != null && data.containsKey('Markers')) {
          final markersMap = data['Markers'];

          if (markersMap.containsKey(label.toLowerCase())) {
            for (var markerData in markersMap[label.toLowerCase()]) {
              final LatLng markerPosition = LatLng(markerData['latitude'], markerData['longitude']);
              final int iconCodePoint = markerData['iconData'];
              final int colorValue = markerData['color'];

              BitmapDescriptor markerIcon = await _getMarkerIconFromIconData(
                IconData(iconCodePoint, fontFamily: 'MaterialIcons'),
                Color(colorValue),
              );

              _markers.add(
                Marker(
                  markerId: MarkerId(markerPosition.toString()),
                  position: markerPosition,
                  icon: markerIcon,
                  infoWindow: InfoWindow(title: "$label Marker"),
                ),
              );
            }
          }
        }
      }

      pressedButtons.add(label); // Add label to pressed set
    }

    setState(() {}); // Trigger UI update
  }

  void _sendRequestToUser(String senderName, String recipientId) async {
    try {
      CollectionReference requests = FirebaseFirestore.instance.collection('Requests');

      // Query the Devices collection to get the sender's profile image
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('Devices')
          .where('username', isEqualTo: senderName)
          .get();

      if (snapshot.docs.isNotEmpty) {
        // Extract the profile image URL from the first document
        String senderImageUrl = snapshot.docs.first['profile_image'] ?? '';

        // Add the request to the 'Requests' collection with the sender's image URL
        await requests.add({
          'SenderName': senderName,
          'recipientName': recipientId,
          'timestamp': FieldValue.serverTimestamp(),
          'status': 'pending',
          'sender_image': senderImageUrl,
        });

        print('Request sent successfully.');
      } else {
        print('Sender profile not found.');
      }
    } catch (e) {
      print('Error sending request: $e');
    }
  }

  Future<void> _showAlertDialog(String searchName, String deviceId) async{

    final recipientId = searchName;
    showDialog(
        context: context,
        builder: (BuildContext context)
    {
      return AlertDialog(
         title: const Text("Friend Request"),
         content: Text("Send Friend Request to $searchName "),
         actions: [
           TextButton(
               child: const Text('Cancel'),
                onPressed: (){
                 Navigator.of(context).pop();
                },
           ),
           TextButton(
               child: const Text('Yes'),
               onPressed: (){
                 _sendRequestToUser(deviceId,recipientId);
                 Navigator.of(context).pop();
               },
           ),
         ],
       );
     }
    );
  }

  Future<List<String>> fetchProfileNames() async{
    List<String> profileNames = [];
    QuerySnapshot snapshot = await FirebaseFirestore.instance.collection('Devices').get();

    for(var doc in snapshot.docs){
      profileNames.add(doc['username']);
    }

    return profileNames;
  }



  void searchUser(String query) async{
    final usersCollection = FirebaseFirestore.instance.collection('Devices');

    QuerySnapshot querySnapshot = await usersCollection
        .where('username', isGreaterThanOrEqualTo : query)
        .where('username', isLessThanOrEqualTo: query + '\uf8ff')
        .get();
      setState(() {
        userList = querySnapshot.docs.map((doc) => doc['username'].toString())
            .where((username) => username != widget.userName)
            .toList();
      });
  }

  Color _getButtonColor(String buttonLabel) {
    return pressedButtons.contains(buttonLabel) ? Colors.green : Colors.purple[50]!;
  }

  Color _getTextColor(String buttonLabel) {
    return pressedButtons.contains(buttonLabel) ? Colors.white : Colors.black;
  }

  var userList = [];
  bool _isExpanded = false;


  void _toggleButtons() async {
    setState(() {
      _isExpanded = !_isExpanded;
    });

    if (_isExpanded) {
      // Clear any old markers
      _markers.clear();

      _markers.add(
        Marker(
          markerId: const MarkerId('currentLocation'),
          position: _initialPosition, // Use the initial position as the marker position
          icon: BitmapDescriptor.defaultMarker, // Default marker icon
        ),
      );

      // Retrieve markers from Firebase
      await _loadMarkersFromFirebase();

      setState(() {}); // Trigger UI update after markers are loaded
    } else {
      // When collapsed, clear the markers and add a default marker
      setState(() {
        _markers.clear();
        _markers.add(
          Marker(
            markerId: const MarkerId('currentLocation'),
            position: _initialPosition,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          ),
        );
      });
    }
  }

  Future<void> _loadMarkersFromFirebase() async {
    // Retrieve markers from Firebase
    final docSnapshot = await FirebaseFirestore.instance.collection('Devices').doc(deviceId).get();

    if (docSnapshot.exists) {
      final data = docSnapshot.data();

      if (data != null && data.containsKey('Markers')) {
        final markersMap = data['Markers'];

        // Loop through each category in the Markers map
        for (var category in ['favorites', 'visited', 'want to go']) {
          if (markersMap.containsKey(category)) {
            for (var markerData in markersMap[category]) {
              // Extract marker details
              final LatLng markerPosition = LatLng(markerData['latitude'], markerData['longitude']);
              final int iconCodePoint = markerData['iconData'];
              final int colorValue = markerData['color'];
              // Create icon with specified color
              BitmapDescriptor markerIcon = await _getMarkerIconFromIconData(IconData(iconCodePoint, fontFamily: 'MaterialIcons'), Color(colorValue));

              // Add marker to the map
              _markers.add(
                Marker(
                  markerId: MarkerId(markerPosition.toString()),
                  position: markerPosition,
                  icon: markerIcon,
                  infoWindow: InfoWindow(title: "$category Marker"),
                ),
              );
            }
          }
        }
      }
    }
    setState(() {}); // Trigger a UI update
  }


  void _onCameraMove(CameraPosition position) {
    // Clear the markers for the current frame

    if(_isExpanded){
    // Add the default marker at the current camera position
    _markers.add(
      Marker(
        markerId: const MarkerId('currentLocation'), // Unique ID for the default marker
        position: position.target, // Use the current camera position
        icon: BitmapDescriptor.defaultMarker, // Default marker icon
        infoWindow: InfoWindow(title: "Current Location"), // Optional info window
      ),
    );

    _addStoredMarkers();


    setState(() {});
   }
  }

  void _addStoredMarkers() async {

    for (MarkerData markerData in _markerPositions) {
      // Fetch the custom icon for the stored marker based on its icon data
      BitmapDescriptor markerIcon = await _getMarkerIconFromIconData(markerData.iconData,markerData.color);

      // Create and add the marker to the list
      _markers.add(
        Marker(
          markerId: MarkerId(markerData.position.toString()), // Use position for unique ID
          position: markerData.position, // Use the stored position
          icon: markerIcon, // Custom marker icon for stored markers
          infoWindow: InfoWindow(title: "Stored Marker"), // Optional info window
        ),
      );
    }

    setState(() {}); // Trigger UI update to display the markers
  }


  Future<BitmapDescriptor> _getMarkerIconFromIconData(IconData iconData,Color color) async{

    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    const double size = 100.0;

    final icon = Icon(
      iconData,
      size: size,
      color: color, // Set the icon color as desired
    );

    final painter = IconPainter(icon);
    painter.paint(canvas,Size(size,size));

    final picture = pictureRecorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());

    final ByteData? byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final Uint8List bytes = byteData!.buffer.asUint8List();

    return BitmapDescriptor.fromBytes(bytes);

  }


  void _addMarker(IconData icon,Color color) async {

    final LatLngBounds bounds = await mapController.getVisibleRegion();

    LatLng markerPosition = LatLng(
      (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
      (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
    );

    BitmapDescriptor markerIcon = await _getMarkerIconFromIconData(icon,color);

    String category;
    if(icon == Icons.favorite){
      category = 'favorites';
    }
    else if(icon == Icons.flag){
      category = 'visited';
    }
    else if(icon == Icons.golf_course){
      category = 'want to go';
    }
    else{
      return;
    }

    _markerPositions.add(MarkerData(position: markerPosition, iconData: icon,color: color));


    setState(() {
      _markers.add(
        Marker(
          markerId: MarkerId(DateTime.now().toString()),
          position: markerPosition,
          icon: markerIcon,
          infoWindow: InfoWindow(title: "Custom Icon Marker"),
        ),
      );
    });

    await FirebaseFirestore.instance.collection('Devices').doc(deviceId).set({
      'Markers':{
        category : FieldValue.arrayUnion([
          {
            'latitude': markerPosition.latitude,
            'longitude': markerPosition.longitude,
            'iconData': icon.codePoint,
            'color': color.value,
          }
        ]),
      }
    }, SetOptions(merge: true));

  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.location_on_rounded,color: Colors.white,size: 25,),
                  SizedBox(width: 5,),
                  Text('Place Tracker App',style: TextStyle(color: Colors.white,fontWeight: FontWeight.bold,fontSize: 21),),
                ],
              ),
              Container(
                child: Padding(
                  padding: const EdgeInsets.only(left: 20.0),
                  child: Row(
                    children: [
                      GestureDetector(
                          onTap:_requestPage,
                          child: Icon(Icons.message,color: Colors.white,size: 22,),
                      ),
                      SizedBox(width: 10,),
                      GestureDetector(
                        onTap: _gotoDashboard,
                        child: const Icon(Icons.list_alt,color: Colors.white,size: 23,),
                      ),
                      IconButton(onPressed: _toggleMapStyle,
                        icon: Icon(isNightVision ? Icons.nights_stay : Icons.sunny,color: Colors.white,),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          GoogleMap(
            onMapCreated: _onMapCreated,
            initialCameraPosition: CameraPosition(
              target: _initialPosition,
              zoom: 11.0,
            ),
            myLocationButtonEnabled: true,
            myLocationEnabled: false,
            markers: _markers,
            onCameraMove: _onCameraMove,
          ),
           Padding(
             padding: const EdgeInsets.all(25.0),
             child: Column(
               children: [
                 SearchAnchor(
                    builder:(BuildContext context , SearchController controller){
                     return SearchBar(
                       controller: controller,
                       onTap: (){
                         controller.openView();
                       },
                       leading: const Icon(Icons.search),
                     );
                    },suggestionsBuilder: (BuildContext context , SearchController controller ) {
                      if(controller.text.isEmpty){
                        return [];
                      }
                      searchUser(controller.text);
                      return userList.map((searchName)=>ListTile(
                        title: Text(searchName),
                        onTap: (){
                          _showAlertDialog(searchName, widget.userName);
                        },
                        )
                      ).toList();

                      // List<String> filteredNames = _profileNames
                      //     .where((name) => name.toLowerCase().contains(controller.text.toLowerCase()))
                      //     .toList();
                      //
                      // return List<ListTile>.generate(filteredNames.length,(int index)   {
                      //   final String item = filteredNames[index];
                      //   String? recipientId = await getRecipientId(item);
                      //   return ListTile(
                      //     title: Text(item),
                      //     onTap: (){
                      //       setState(() {
                      //         _showAlertDialog(item,deviceId,recipientId);
                      //       });
                      //     },
                      //   );
                      // }
                   }
                 ),
                 SizedBox(height: 10),
                 // Space between SearchBar and Button
                 Align(
                   alignment: Alignment.centerRight,
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.end,
                     children: [
                       SizedBox(
                         height: 60,
                         child: ElevatedButton(
                           onPressed: _toggleButtons,
                           style:ElevatedButton.styleFrom(backgroundColor:Colors.green),
                           child: Icon(Icons.location_on,
                           size: 25,color: Colors.white,
                           ),
                         ),
                       ),
                       if(_isExpanded) ... [
                         SizedBox( height: 10),
                           SizedBox(
                             height: 50,
                             width: 70,
                             child: ElevatedButton(
                               style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                               onPressed: () {
                                 _addMarker(Icons.favorite,Colors.red); // Add marker for favorite icon
                               },
                               child: Icon(Icons.favorite,
                                 size: 25,color: Colors.red,
                               ),
                             ),
                           ),
                         SizedBox( height: 10),
                           SizedBox(
                             height: 50,
                             width: 70,
                             child: ElevatedButton(
                               style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                               onPressed: (){
                                 _addMarker(Icons.flag,Colors.blue);
                               },
                               child: Icon(Icons.flag,
                                 size: 25,color: Colors.blue,
                               ),
                             ),
                           ),
                         SizedBox( height: 10),
                           SizedBox(
                             height: 50,
                             width: 70,
                             child: ElevatedButton(
                               style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                               onPressed: (){
                                 _addMarker(Icons.golf_course,Colors.yellow);
                               },
                               child: Icon(Icons.golf_course,
                                 size: 25,color: Colors.yellow,
                               ),
                             ),
                           ),
                       ]
                     ],
                   ),
                 ),
               ],
             ),
           ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Row(
              children: [
                _buildButton('Favorites'),
                _buildButton('Visited'),
                Expanded(child: _buildButton('Want to go')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Padding _buildButton(String label) {
    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: ElevatedButton(
        onPressed: () {
          _toggleButton(label);
        },
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(100, 50),
          backgroundColor: _getButtonColor(label),
        ),
        child: Text(
          label,
          style: TextStyle(color: _getTextColor(label)),
        ),
      ),
    );
  }


}

class RequestPage extends StatefulWidget{
  const RequestPage({super.key});

  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends State<RequestPage> {

  String? _currentUsername;
  List <Map<String,dynamic>> _requests = [];

  @override
  void initState(){
    super.initState();
    _getCurrentUserName();
  }

  Future<void> _getCurrentUserName() async{
    User? user = FirebaseAuth.instance.currentUser;
    if(user !=null){
      try {
        QuerySnapshot querySnapshot = await FirebaseFirestore.instance
            .collection('Devices')
            .where('username', isEqualTo: user.displayName)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          DocumentSnapshot userDoc = querySnapshot.docs.first;
          setState(() {
            _currentUsername = userDoc['username'];
          });
          _getRequests();
        }
      } catch (e) {
        print('Error getting userDoc: $e');
      }
    }

  }

  Future<void> _getRequests() async {
    if(_currentUsername !=null){
      QuerySnapshot snapshot = await FirebaseFirestore.instance
          .collection('Requests')
          .where('recipientName',isEqualTo: _currentUsername)
          .get();

      setState(() {
        _requests = snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          data['requestId'] = doc.id;
          return data;
        }).toList();
      });
    }
  }

  void _acceptRequest(String requestId , String senderName , String recipientName) async{
    try {
      await FirebaseFirestore.instance.collection('Requests')
          .doc(requestId)
          .update({
        'status': 'accepted',
      });

      var deviceSnapshot = await FirebaseFirestore.instance
          .collection('Devices')
          .where('username' , isEqualTo: recipientName)
          .get();

      if (deviceSnapshot.docs.isNotEmpty) {
        String recipientDocId = deviceSnapshot.docs.first.id;

        await FirebaseFirestore.instance.collection('Devices')
            .doc(recipientDocId)
            .update({
          'Friends': FieldValue.arrayUnion([senderName])
        });

        var senderDoc = await FirebaseFirestore.instance
            .collection('Devices')
            .where('username', isEqualTo: senderName)
            .get();

        if (senderDoc.docs.isNotEmpty) {
          String senderDeviceId = senderDoc.docs.first.id;

          await FirebaseFirestore.instance.collection('Devices').doc(senderDeviceId).update({
            'Friends': FieldValue.arrayUnion([recipientName]),
          });
        }


        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request accepted!')),
        );
      } else {
        throw 'Recipient not found in Devices collection';
      }
      _getRequests();
    }
     catch(e){
      print('Error accepting request: $e');
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
         content: Text('Failed to accept request.'),
       ));
    }

  }
  void _declineRequest(String requestId){
    FirebaseFirestore.instance.collection('Requests').doc(requestId).update({
      'status' : 'declined',
    }).then((_){

      setState(() {
        _requests.removeWhere((request) => request['requestId'] == requestId);
      });

      ScaffoldMessenger.of(context).showSnackBar(const
      SnackBar
        (content: Text('Request declined!'),
      ));
      _getRequests();
    });

  }

  void _deleteRequest(String requestId , String senderName)  async {
    try {
      await FirebaseFirestore.instance.collection('Requests')
          .doc(requestId)
          .delete();

      await FirebaseFirestore.instance.collection('Devices')
      .where('username' , isEqualTo: _currentUsername)
      .get()
      .then((querySnapshot) async {
        if(querySnapshot.docs.isNotEmpty){
          String recipientDeviceId = querySnapshot.docs.first.id;

          await FirebaseFirestore.instance.collection('Devices').doc(recipientDeviceId).update({
            'Friends': FieldValue.arrayRemove([senderName]),
          });
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend Deleted!')),
      );
      _getRequests();
    }
    catch(e){
      print('Error deleting request: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to delete request.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      backgroundColor: Colors.green,
      title: Row(
        children: [
          GestureDetector(
            onTap: () {
              context.go('/map', extra: SlideDirection.backward);
            },
            child: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 20),
          const Text('Requests', style: TextStyle(color: Colors.white),),
        ],
      ),
    ),
    body: _requests.isEmpty
        ? const Center(child: Text('No Requests Found'))
        : ListView.builder(
           itemCount: _requests.length,
           itemBuilder: (context, index) {
               final request = _requests[index];
               final senderName = request['SenderName'];
               final senderAvatarUrl = request['sender_image'];
               final requestStatus = request['status'];
              return Column(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundImage: senderAvatarUrl != null && senderAvatarUrl.isNotEmpty
                          ? NetworkImage(senderAvatarUrl)
                          : const AssetImage('assets/default_avatar.png'),
                    ),
                    title: Text( requestStatus == 'accepted'
                        ? '$senderName is now a Friend !! '
                        : 'Request is Sent By $senderName',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if(requestStatus == 'pending')...[
                          TextButton(
                            onPressed: () {
                              _declineRequest(request['requestId']);
                              _deleteRequest(request['requestId'],request['SenderName']);
                            },
                          child: const Text('Decline'),
                        ),
                        TextButton(
                          onPressed: () {
                            _acceptRequest(request['requestId'], request['SenderName'] , _currentUsername!);
                          },
                          child: const Text('Accept'),
                        ),
                    ] else if(requestStatus == 'accepted') ... [
                          TextButton(
                            onPressed: () {
                              _deleteRequest(request['requestId'],request['SenderName']);
                            },
                            child: const Text('Delete'),
                          )
                        ],
                      ],
                    ),
                  ),
                  const Divider(), // Add a line after each request
                ],
              );
            },
          ),
        );
  }
 }

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {

  PageController _pageController = PageController();
  int _currentIndex = 0;

  Map<String, List<MarkerData>> _markersByCategory = {
    'Favorites': [],
    'Visited': [],
    'Want to go': []
  };

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  void initState() {
    super.initState();
    _fetchMarkersFromFirebase(); // Fetch marker data from Firebase when the page loads
  }

  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _fetchMarkersFromFirebase() async {
    String deviceId = await getDeviceId();
    final docSnapshot = await FirebaseFirestore.instance.collection('Devices').doc(deviceId).get();

    if (docSnapshot.exists) {
      final data = docSnapshot.data();
      if (data != null && data.containsKey('Markers')) {
        final markersMap = data['Markers'];

        // Populate _markersByCategory with Firebase data
        for (var category in ['favorites', 'visited', 'want to go']) {
          if (markersMap.containsKey(category.toLowerCase())) {
            _markersByCategory[category] = (markersMap[category.toLowerCase()] as List)
                .map((markerData) => MarkerData(
              position: LatLng(markerData['latitude'], markerData['longitude']),
              iconData: IconData(markerData['iconData'], fontFamily: 'MaterialIcons'),
              color: Color(markerData['color']),
            ))
                .toList();
          }
        }
      }
    }
    setState(() {}); // Update UI with fetched marker data
  }

  Future<bool> signOutFromGoogle() async {
    try {
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();

      return true;

    }
    on Exception catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: Row(
          children: [
            GestureDetector(
              onTap: () {
                context.go('/map', extra: SlideDirection.backward);
              },
              child: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 20),
            const Text('Dashboard', style: TextStyle(color: Colors.white),),
            
            Padding(
              padding: const EdgeInsets.only(left: 170.0),
              child: GestureDetector(
                onTap: () async {
                  bool signOutSuccess = await signOutFromGoogle();
                  if(signOutSuccess){
                  context.go ('/');
                  }
                  else{
                    print('Error during sign out');
                  }
                },
                  child: const Icon(Icons.power_settings_new)
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Section Titles
          Container(
            padding: const EdgeInsets.all(25),
            color: Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildSectionTitle("Favorites", 0),
                _buildSectionTitle("Visited", 1),
                _buildSectionTitle("Want to go", 2),
              ],
            ),
          ),
          // Sliding Content
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              children: [
                _buildSectionContent("Favorites", Icons.favorite, Colors.red),
                _buildSectionContent(
                    "Visited", Icons.check_circle, Colors.green),
                _buildSectionContent(
                    "Want to go", Icons.location_on, Colors.blue),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, int index) {
    bool isActive = _currentIndex == index;
    return GestureDetector(
      onTap: () {
        _pageController.jumpToPage(index);
      },
      child: Column(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isActive ? Colors.green : Colors.black,
            ),
          ),
          const SizedBox(height: 5,),
          if(isActive)
            Container(
              width: 50,
              height: 3,
              color: Colors.green,
            ),
        ],
      ),

    );
  }

  // A helper function to build the content for each section
  Widget _buildSectionContent(String title, IconData icon, Color iconColor) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: iconColor, size: 60),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          if (_markersByCategory[title]?.isNotEmpty ?? false)
            Expanded(
              child: ListView.builder(
                itemCount: _markersByCategory[title]?.length ?? 0,
                itemBuilder: (context, index) {
                  final marker = _markersByCategory[title]![index];
                  return ListTile(
                    leading: Icon(marker.iconData, color: marker.color),
                    title: Text("Marker at ${marker.position.latitude}, ${marker.position.longitude}"),
                  );
                },
              ),
            )
          else
            const Text("No markers in this category."),
        ],
      ),
    );
  }
}


enum SlideDirection { forward, backward }

Widget _slideTransition(
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
    GoRouterState state,
    ) {
  final SlideDirection direction = state.subloc == '/dashboard'
      ? SlideDirection.forward
      : SlideDirection.backward;

  final Offset begin = (direction == SlideDirection.forward)
      ? const Offset(1.0, 0.0) // Forward slide (right to left)
      : const Offset(-1.0, 0.0); // Backward slide (left to right)

  const end = Offset.zero;
  const curve = Curves.easeInOut;

  final tween = Tween<Offset>(begin: begin, end: end).chain(CurveTween(curve: curve));
  final offsetAnimation = animation.drive(tween);

  return SlideTransition(
    position: offsetAnimation,
    child: child,
  );
}
