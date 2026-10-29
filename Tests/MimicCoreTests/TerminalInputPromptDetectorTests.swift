//
//  TerminalInputPromptDetectorTests.swift
//  MimicCoreTests
//
//  Created by Василий Маслов on 27.10.2026.
import Foundation
import Testing
import MimicCore

struct TerminalInputPromptDetectorTests {
    @Test(arguments: [
        "[15:32:02]: Passphrase for Match storage: ",
        "Password for 'https://example.invalid': ",
        "[sudo] password for fixture: ",
        "Please enter your Apple ID: ",
        "Verification code: ",
        "Select a team: ",
        "Continue? [Y/n] ",
        "Continue? (yes/no): ",
        "Press any key to continue...",
        "Введите пароль: "
    ])
    func promptSurvivesEveryPossibleChunkBoundary(_ prompt: String) {
        let bytes = Data(prompt.utf8)
        for boundary in 0...bytes.count {
            var detector = TerminalInputPromptDetector()
            _ = detector.consume(Data(bytes.prefix(boundary)))
            #expect({ detector.consume(Data(bytes.dropFirst(boundary))) }())
        }
    }

    @Test func ansiAndExplanatoryOutputDoNotHideTheMatchPrompt() {
        var detector = TerminalInputPromptDetector()
        #expect({ !detector.consume(Data("Enter the passphrase that should be used to encrypt/decrypt your certificates\r\n".utf8)) }())
        #expect({ !detector.consume(Data("This passphrase is specific per repository and will be stored in your local keychain\r\n".utf8)) }())
        #expect({ detector.consume(Data("\u{1b}[32m[15:32:02]: Passphrase for Match storage: \u{1b}[0m".utf8)) }())
        #expect({ !detector.consume(Data("\r\nCertificates decrypted successfully\r\n".utf8)) }())
    }

    @Test func acceptedInputAndLaterOutputCannotRediscoverTheOldPrompt() {
        var detector = TerminalInputPromptDetector()
        #expect({ detector.consume(Data("Passphrase for Match storage: ".utf8)) }())
        detector.reset()
        #expect({ !detector.consume(Data("\u{1b}[0m".utf8)) }())
        #expect({ !detector.consume(Data("Using mint\r\nInstalling dependencies\r\n".utf8)) }())
        #expect({ !detector.consume(Data("Make sure to remember the password, as you'll need it later\r\n".utf8)) }())
        #expect({ detector.consume(Data("Verification code: ".utf8)) }())
    }
}
