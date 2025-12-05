import QtQuick 2.0
import MuseScore 3.0

MuseScore {
    title: "Chord Pro Export"
    version: "0.2"
    description: "This plugin exports chord pro format from the score"
    menuPath: "Plugins.Chord Pro Export"

    requiresScore: true

    onRun: {
        var cursor = curScore.newCursor();
        // Check if the score has lyrics and chords
        if (!checkScoreForLyricsAndChords(cursor)) {
            console.log("The score does not contain both lyrics and chords.");
            //TODO Show error to user?
            return;
        }

        cursor.rewind(Cursor.SCORE_START);
        var chordsAndLyrics = extract(cursor);
        var metadata = extractMetadata();
        var chordPro = buildChordPro(metadata, chordsAndLyrics.chordSheet);
        copyTextToClipboard(chordPro);
    }

    TextEdit {
        id: textEdit
        visible: false
    }

    function checkScoreForLyricsAndChords(cursor) {
        if (curScore) {
            let hasLyrics = false;
            let hasChords = false;
            const endTick = curScore.lastSegment.tick + 1;
            for (var staff = 0; staff < curScore.nstaves; staff++) {
                for (var voice = 0; voice < 4; voice++) {
                    cursor.voice = voice;
                    //voice has to be set after goTo
                    cursor.staffIdx = staff;
                    cursor.rewind(Cursor.SCORE_START);
                    while (cursor.segment && (cursor.tick < endTick)) {

                        if (cursor.element && cursor.element.type === Element.CHORD) {
                            if (cursor.segment.annotations &&
                                cursor.segment.annotations.length > 0 &&
                                cursor.segment.annotations[0].name === "Harmony") {
                                hasChords = true;
                            }

                            var lyrics = cursor.element.lyrics;
                            if (lyrics && lyrics.length > 0) {
                                hasLyrics = true;
                            }
                        }

                        if (hasLyrics && hasChords) {
                            break;
                        }
                        cursor.next();
                    }
                }
            }

            if (hasLyrics && hasChords) {
                return true;
            } else if (hasLyrics) {
                console.log("The score contains lyrics but no chords.");
                return false;
            } else if (hasChords) {
                console.log("The score contains chords but no lyrics.");
                return false;
            } else {
                console.log("The score contains neither lyrics nor chords.");
                return false;
            }
        } else {
            return false;
        }
    }

    /**
     * returns an Array of objects: { measure: Measure, verse: int }
     * 'verse' is the 0-based index of the repeat iteration (0=1st time, 1=2nd time).
     */
    function getPlaybackSequence(score) {
        // 1. Linearize the score
        var measures = [];
        var m = score.firstMeasure;
        while (m) {
            measures.push(m);
            m = m.nextMeasure;
        }

        // 2. Map Voltas
        var voltaMap = getVoltaMap(score, measures);
        // 3. Simulation Variables
        var playbackSequence = [];
        var currentIdx = 0;
        // Tracks repeat structure iterations
        var repeatPassCounts = {};
        // Tracks how many times we have visited a specific measure index.
        var measureVisitCounts = {};
        var safetyCounter = 0;
        var MAX_ITERATIONS = 10000;

        while (currentIdx < measures.length) {
            if (safetyCounter++ > MAX_ITERATIONS) {
                console.log("Safety limit reached.");
                break;
            }

            var currentMeasure = measures[currentIdx];
            var skipMeasure = false;

            // --- A. Volta Logic (FIXED) ---
            var controllingRepeatEndIdx = -1;
            if (voltaMap[currentIdx]) {
                var volta = voltaMap[currentIdx];

                // FIX: Determine search direction for controlling repeat sign.
                var isFirstEnding = volta.endings.indexOf(1) !== -1;

                if (isFirstEnding) {
                    // Look Forward for the closing repeat
                    for (var s = currentIdx; s < measures.length; s++) {
                        if (measures[s].repeatEnd) {
                            controllingRepeatEndIdx = s;
                            break;
                        }
                    }
                } else {
                    // Look Backward for the repeat we just finished
                    for (var b = currentIdx - 1; b >= 0; b--) {
                        if (measures[b].repeatEnd) {
                            controllingRepeatEndIdx = b;
                            break;
                        }
                        // Stop if we hit the start of the repeat to avoid grabbing a repeat from a previous song section
                        if (measures[b].repeatStart) break;
                    }
                }

                if (controllingRepeatEndIdx !== -1) {
                    var currentPass = (repeatPassCounts[controllingRepeatEndIdx] || 0) + 1;
                    if (volta.endings.indexOf(currentPass) === -1) {
                        skipMeasure = true;
                    }
                }
            }

            if (currentIdx === 24 && measureVisitCounts[currentIdx] === 1) {
                console.log("Debug: At measure 25 second visit - skipMeasure=" + skipMeasure);
            }

            // --- C. Volta Skip/Jump Fix (NEW) ---
            if (skipMeasure) {
                // Find the end of the current Volta group to jump past it
                var jumpTargetIdx = currentIdx;

                // Find the last consecutive measure that is part of a Volta
                for (var j = currentIdx; j < measures.length; j++) {
                    if (voltaMap[j]) {
                        jumpTargetIdx = j;
                    } else {
                        // This measure is NOT part of a Volta, so the previous index was the end.
                        break;
                    }
                }

                // Jump the index past the last measure of the volta group
                currentIdx = jumpTargetIdx + 1;
                continue; // Skip the rest of the loop for this iteration
            }
            // --- End Volta Skip/Jump Fix ---


            if (!skipMeasure) {
                // Determine Verse based on visits
                var visits = measureVisitCounts[currentIdx] || 0;

                playbackSequence.push({
                    measure: currentMeasure,
                    verse: visits
                });
                measureVisitCounts[currentIdx] = visits + 1;
            }

            // --- B. Repeat Logic ---
            if (currentMeasure.repeatEnd) {
                if (repeatPassCounts[currentIdx] === undefined) {
                    repeatPassCounts[currentIdx] = 0;
                }

                repeatPassCounts[currentIdx]++;
                var requiredPlays = currentMeasure.repeatCount;

                if (repeatPassCounts[currentIdx] < requiredPlays) {
                    // LOOP BACK
                    var loopDest = 0;
                    for (var b = currentIdx; b >= 0; b--) {
                        if (measures[b].repeatStart) {
                            loopDest = b;
                            break;
                        }
                    }
                    currentIdx = loopDest;
                    continue;
                } else {
                    // REPEAT FINISHED
                    repeatPassCounts[currentIdx] = 0;
                }
            }

            currentIdx++;
        }
        const debugSequence = playbackSequence.map(item => {
            return {
                measureIdx: measures.indexOf(item.measure) + 1,
                verse: item.verse
            };
        });
        console.log(JSON.stringify(debugSequence));

        return playbackSequence;
    }

    function getVoltaMap(score, measureList) {
        var map = {};
        var voltasFound = [];
        // Use a dictionary to track IDs to ensure we only process unique Volta elements once
        var uniqueVoltaIds = {};
        // 1. Find all unique Volta elements by iterating through all segments
        for (var mIdx = 0; mIdx < measureList.length; mIdx++) {
            var m = measureList[mIdx];
            var seg = m.firstSegment;
            while (seg) {
                // Check all tracks in the segment
                for (var t = 0; t < score.ntracks; t++) {
                    var element = seg.elementAt(t);
                    if (element && (element.type === Element.VOLTA || element.type === Element.VOLTA_SEGMENT)) {
                        // The element itself is the Volta spanner object
                        if (!uniqueVoltaIds[element.id]) {
                            voltasFound.push(element);
                            uniqueVoltaIds[element.id] = true;
                            break; // No need to check other tracks for this segment
                        }
                    }
                }
                seg = seg.nextInMeasure;
            }
        }
        console.log("Voltas found:", voltasFound.length);

        // 2. Process the found Voltas and map them to measure indices
        for (var i = 0; i < voltasFound.length; i++) {
            var s = voltasFound[i];
            var startTick = s.startSegment.tick;
            var endTick = 0;
            if (s.endSegment) {
                endTick = s.endSegment.tick;
            } else {
                endTick = startTick + s.duration;
            }

            var endings = s.endings;
            // Map this volta to every measure falling within its ticks
            for (var m = 0; m < measureList.length; m++) {
                var meas = measureList[m];
                var mStart = meas.firstSegment.tick;

                // Check overlap: measure starts on or after volta start, and before volta end
                if (mStart >= startTick && mStart < endTick) {
                    map[m] = { endings: endings };
                }
            }
        }
        console.log("Volta Map:", JSON.stringify(map));
        return map;
    }

    function extract(cursor) {
        if (!curScore) {
            console.log("No score is currently loaded.");
            return;
        }
        console.log("Starting extraction...");
        // Get the "unrolled" list of objects { measure, verse }
        var sequence = getPlaybackSequence(curScore);
        const endTick = curScore.lastSegment.tick;
        // --- Extract Lyrics ---
        var fullLyrics = "";
        let lastSyllabComplete = true;
        for (var i = 0; i < sequence.length; i++) {
            var item = sequence[i];
            var m = item.measure;
            var targetVerse = item.verse; // 0 = Verse 1, 1 = Verse 2, etc.

            // Iterate through all segments in the measure
            var fistSegment = m.firstSegment;

            cursor.rewind(0);
            // Reset cursor to avoid stale state
            cursor.voice = 0;
            // Always check voice 0 for lyrics
            //for (var t = 0; t < curScore.nstaves; t++) {
                cursor.staffIdx = 2; //TODO : Make configurable with UI
                cursor.rewindToTick(fistSegment.tick);

                let seg = cursor.segment;

                while (seg) {
                    if (seg.annotations && seg.annotations.length > 0) {
                        const sectionAnnotation = seg.annotations.find(ann => {
                            return /verse\s?\d?|intro|chorus\s?\d?|bridge|outro|interlude|instrumental/ig.test(ann.text); //TODO: expand as needed
                        });
                        if (sectionAnnotation) {
                            fullLyrics += "\n\n" + sectionAnnotation.text + "\n";
                            // THIS could setup section wrapping?
                        }

                        const chordAnnotation = seg.annotations.find(ann => ann.name === "Harmony");
                        if (chordAnnotation) {
                            fullLyrics += "[" + chordAnnotation.text + "]";
                        }
                    }

                    for (let track = 0; track < curScore.ntracks; track++) {
                        let element = seg.elementAt(track);

                        if (element && element.type === Element.CHORD) {

                            // Lyrics are stored in the 'lyrics' property of a Chord
                            var lyricsList = element.lyrics;
                            const maxVerse = Math.max(...lyricsList.map(l => l.verse));
                            const currentVerse = targetVerse <= maxVerse ? targetVerse : maxVerse;
                            for (var l = 0; l < lyricsList.length; l++) {
                                var lyric = lyricsList[l];
                                // Check if this lyric belongs to the current verse iteration

                                if (lyric.verse === currentVerse) {

                                    // formatting: add a space after the syllable
                                    const noSpace = lyric.syllabic === Lyrics.BEGIN || lyric.syllabic === Lyrics.MIDDLE;
                                    fullLyrics += lyric.text + (noSpace ? "" : " ");
                                    lastSyllabComplete = !(noSpace);
                                }
                            }
                        }
                    }

                    seg = seg.nextInMeasure;
                }
            //}


            // Logic to add newlines based on layout or structure
            var addNewLine = false;
            // 1. Check for manual breaks on current measure
            if (m.lineBreak || m.pageBreak) {
                addNewLine = true;
            }
            // 2. Check layout/sequence transition
            else if (i < sequence.length - 1) {
                var nextM = sequence[i+1].measure;
                // Check for non-linear jump (Repeat/Da Capo)
                // Need to use optional chaining for nextMeasure and measure, which is currently supported by the environment's version of JS
                if (m.nextMeasure?.tick !== nextM.measure?.tick) {
                    addNewLine = true;
                }
                // Check for automatic system break (Visual wrapping)
                // else if (m.system !== nextM.system) {
                //     addNewLine = true;
                // }
            }

            if (addNewLine && lastSyllabComplete) {
                fullLyrics += "\n";
            }
        }
        
        return {
            chordSheet: fullLyrics
        };
    }

    function extractMetadata() {
        if (!curScore) {
            console.log("No score is currently loaded.");
            return;
        }

        let metadata = {};
        metadata.title = curScore.title;
        metadata.composer = curScore.composer;
        metadata.lyricist = curScore.lyricist;
        const keysigMap = {
           "0": "C",
           "1": "G",
           "2": "D",
           "3": "A",
           "4": "E",
           "5": "B",
           "6": "F#",

           "7": "C#",
           "-1": "F",
           "-2": "Bb",
           "-3": "Eb",
           "-4": "Ab",
           "-5": "Db",
           "-6": "Gb",
           "-7": "Cb"
        };
        metadata.key = keysigMap[curScore.keysig.toString()];


        console.log("Extracted Metadata:", metadata);
        return metadata;
    }

    function buildChordPro(metadata, chordSheet) {
        let chordPro = "";
        if (metadata.title) {
            chordPro += "{title: " + metadata.title + "}\n";
        }
        if (metadata.composer) {
            chordPro += "{composer: " + metadata.composer + "}\n";
        }
        if (metadata.lyricist) {
            chordPro += "{lyricist: " + metadata.lyricist + "}\n";
        }
        if (metadata.key) {
            chordPro += "{key: " + metadata.key + "}\n";
        }
        chordPro += "\n" + chordSheet;
        console.log("Built ChordPro Format:\n", chordPro);
        return chordPro;
    }

    function copyTextToClipboard(text) {
        if (!text) {
            console.log("No text to copy to clipboard.");
            return;
        }

        textEdit.text = text;
        textEdit.selectAll();
        textEdit.copy();
        console.log("Data copied to clipboard.");
    }

}