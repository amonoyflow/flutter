// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';

import '../artifacts.dart';
import '../base/file_system.dart';
import '../build_info.dart';
import '../bundle.dart';
import '../codegen.dart';
import '../compile.dart';
import '../dart/package_map.dart';
import '../globals.dart' as globals;
import '../project.dart';

/// A request to the [TestCompiler] for recompilation.
class _CompilationRequest {
  _CompilationRequest(this.mainUri, this.result);

  Uri mainUri;
  Completer<String> result;
}

/// A frontend_server wrapper for the flutter test runner.
///
/// This class is a wrapper around compiler that allows multiple isolates to
/// enqueue compilation requests, but ensures only one compilation at a time.
class TestCompiler {
  /// Creates a new [TestCompiler] which acts as a frontend_server proxy.
  ///
  /// [trackWidgetCreation] configures whether the kernel transform is applied
  /// to the output. This also changes the output file to include a '.track`
  /// extension.
  ///
  /// [flutterProject] is the project for which we are running tests.
  TestCompiler(
    this.buildMode,
    this.trackWidgetCreation,
    this.flutterProject,
    this.extraFrontEndOptions,
  ) : testFilePath = getKernelPathForTransformerOptions(
        globals.fs.path.join(flutterProject.directory.path, getBuildDirectory(), 'testfile.dill'),
        trackWidgetCreation: trackWidgetCreation,
      ) {
    // Compiler maintains and updates single incremental dill file.
    // Incremental compilation requests done for each test copy that file away
    // for independent execution.
    final Directory outputDillDirectory = globals.fs.systemTempDirectory.createTempSync('flutter_test_compiler.');
    outputDill = outputDillDirectory.childFile('output.dill');
    globals.printTrace('Compiler will use the following file as its incremental dill file: ${outputDill.path}');
    globals.printTrace('Listening to compiler controller...');
    compilerController.stream.listen(_onCompilationRequest, onDone: () {
      globals.printTrace('Deleting ${outputDillDirectory.path}...');
      outputDillDirectory.deleteSync(recursive: true);
    });
  }

  final StreamController<_CompilationRequest> compilerController = StreamController<_CompilationRequest>();
  final List<_CompilationRequest> compilationQueue = <_CompilationRequest>[];
  final FlutterProject flutterProject;
  final BuildMode buildMode;
  final bool trackWidgetCreation;
  final String testFilePath;
  final List<String> extraFrontEndOptions;


  ResidentCompiler compiler;
  File outputDill;

  Future<String> compile(Uri mainDart) {
    final Completer<String> completer = Completer<String>();
    if (compilerController.isClosed) {
      return null;
    }
    compilerController.add(_CompilationRequest(mainDart, completer));
    return completer.future;
  }

  Future<void> _shutdown() async {
    // Check for null in case this instance is shut down before the
    // lazily-created compiler has been created.
    if (compiler != null) {
      await compiler.shutdown();
      compiler = null;
    }
  }

  Future<void> dispose() async {
    await compilerController.close();
    await _shutdown();
  }

  /// Create the resident compiler used to compile the test.
  @visibleForTesting
  Future<ResidentCompiler> createCompiler() async {
    final ResidentCompiler residentCompiler = ResidentCompiler(
      globals.artifacts.getArtifactPath(Artifact.flutterPatchedSdkPath),
      artifacts: globals.artifacts,
      logger: globals.logger,
      processManager: globals.processManager,
      buildMode: buildMode,
      trackWidgetCreation: trackWidgetCreation,
      initializeFromDill: testFilePath,
      unsafePackageSerialization: false,
      dartDefines: const <String>[],
      packagesPath: globalPackagesPath,
      extraFrontEndOptions: extraFrontEndOptions,
    );
    if (flutterProject.hasBuilders) {
      return CodeGeneratingResidentCompiler.create(
        residentCompiler: residentCompiler,
        flutterProject: flutterProject,
      );
    }
    return residentCompiler;
  }

  PackageConfig _packageConfig;

  // Handle a compilation request.
  Future<void> _onCompilationRequest(_CompilationRequest request) async {
    final bool isEmpty = compilationQueue.isEmpty;
    compilationQueue.add(request);
    // Only trigger processing if queue was empty - i.e. no other requests
    // are currently being processed. This effectively enforces "one
    // compilation request at a time".
    if (!isEmpty) {
      return;
    }
    if (_packageConfig == null) {
      _packageConfig ??= await loadPackageConfigWithLogging(
        globals.fs.file(globalPackagesPath),
        logger: globals.logger,
      );
      // Compilation will fail if there is no flutter_test dependency, since
      // this library is imported by the generated entrypoint script.
      if (_packageConfig['flutter_test'] == null) {
        globals.printError(
          '\n'
          'Error: cannot run without a dependency on "package:flutter_test". '
          'Ensure the following lines are present in your pubspec.yaml:'
          '\n\n'
          'dev_dependencies:\n'
          '  flutter_test:\n'
          '    sdk: flutter\n',
        );
        request.result.complete(null);
        await compilerController.close();
        return;
      }
    }
    while (compilationQueue.isNotEmpty) {
      final _CompilationRequest request = compilationQueue.first;
      globals.printTrace('Compiling ${request.mainUri}');
      final Stopwatch compilerTime = Stopwatch()..start();
      bool firstCompile = false;
      if (compiler == null) {
        compiler = await createCompiler();
        firstCompile = true;
      }
      final CompilerOutput compilerOutput = await compiler.recompile(
        request.mainUri,
        <Uri>[request.mainUri],
        outputPath: outputDill.path,
        packageConfig: _packageConfig,
      );
      final String outputPath = compilerOutput?.outputFilename;

      // In case compiler didn't produce output or reported compilation
      // errors, pass [null] upwards to the consumer and shutdown the
      // compiler to avoid reusing compiler that might have gotten into
      // a weird state.
      final String path = request.mainUri.toFilePath(windows: globals.platform.isWindows);
      if (outputPath == null || compilerOutput.errorCount > 0) {
        request.result.complete(null);
        await _shutdown();
      } else {
        final File outputFile = globals.fs.file(outputPath);
        final File kernelReadyToRun = await outputFile.copy('$path.dill');
        final File testCache = globals.fs.file(testFilePath);
        if (firstCompile || !testCache.existsSync() || (testCache.lengthSync() < outputFile.lengthSync())) {
          // The idea is to keep the cache file up-to-date and include as
          // much as possible in an effort to re-use as many packages as
          // possible.
          globals.fsUtils.ensureDirectoryExists(testFilePath);
          await outputFile.copy(testFilePath);
        }
        request.result.complete(kernelReadyToRun.path);
        compiler.accept();
        compiler.reset();
      }
      globals.printTrace('Compiling $path took ${compilerTime.elapsedMilliseconds}ms');
      // Only remove now when we finished processing the element
      compilationQueue.removeAt(0);
    }
  }
}
