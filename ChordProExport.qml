import QtQuick;
import MuseScore 3.0;

MuseScore {
    title: "Chord Pro Export"
    version: "0.1"
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
                    cursor.voice = voice; //voice has to be set after goTo
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

    function extract(cursor) {
        if (!curScore) {
            console.log("No score is currently loaded.");
            return;
        }
        const chordSheetItems = [];
        const endTick = curScore.lastSegment.tick + 1;
        console.log("Starting extraction...");

        for (var staff = 0; staff < curScore.nstaves; staff++) {
            for (var voice = 0; voice < 4; voice++) {
                cursor.rewind(1); 
                cursor.voice = voice; //voice has to be set after goTo
                cursor.staffIdx = staff; //TODO: ability to chose staff with a UI
                cursor.rewind(Cursor.SCORE_START);
                while (cursor.segment && (cursor.tick < endTick)) {
                    if (cursor.segment.annotations && cursor.segment.annotations.length > 0) {

                        const sectionAnnotation = cursor.segment.annotations.find(ann => {
                            return /verse\s?\d+|intro|chorus\s?\d+|bridge|outro/ig.test(ann.text); //TODO: expand as needed
                        });
                        if (sectionAnnotation) {
                            chordSheetItems.push("\n\n" + sectionAnnotation.text + "\n"); // THIS could setup section wrapping?
                        }

                        const chordAnnotation = cursor.segment.annotations.find(ann => ann.name === "Harmony");
                        if (chordAnnotation) {
                            chordSheetItems.push("[" + chordAnnotation.text + "]");
                        }
                    }
                    if (cursor.element && cursor.element.type === Element.CHORD) {
                        var lyrics = cursor.element.lyrics;
                        if (lyrics && lyrics.length > 0) {
                            // TODO Check multi verse handling, I suspect this is wrong
                            const all = lyrics.map(l => {
                                    const noSpace = l.syllabic === Lyrics.BEGIN || l.syllabic === Lyrics.MIDDLE
                                    return l.text + (noSpace ? "" : " ");
                                }).join(" "); // TODO: should this be space or not?
                            chordSheetItems.push(all);
                        }
                    }

                    //TODO: consider line breaks, measure ends, etc.

                    cursor.next();
                }
            }
        }
        const chordSheet = chordSheetItems.join("");

        return {
            chordSheet: chordSheet
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
