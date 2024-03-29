import { CustomError } from "@ente/shared/error";
import { addLocalLog, addLogLine } from "@ente/shared/logging";
import { isPlaybackPossible } from "@ente/shared/media/video-playback";
import { logError } from "@ente/shared/sentry";
import { LS_KEYS, getData } from "@ente/shared/storage/localStorage";
import { User } from "@ente/shared/user/types";
import { convertBytesToHumanReadable } from "@ente/shared/utils/size";
import {
    FILE_TYPE,
    RAW_FORMATS,
    SUPPORTED_RAW_FORMATS,
    TYPE_HEIC,
    TYPE_HEIF,
} from "constants/file";
import CastDownloadManager from "services/castDownloadManager";
import * as ffmpegService from "services/ffmpeg/ffmpegService";
import heicConversionService from "services/heicConversionService";
import { decodeLivePhoto } from "services/livePhotoService";
import { getFileType } from "services/typeDetectionService";
import {
    EncryptedEnteFile,
    EnteFile,
    FileMagicMetadata,
    FilePublicMagicMetadata,
} from "types/file";
import { FileTypeInfo } from "types/upload";
import ComlinkCryptoWorker from "utils/comlink/ComlinkCryptoWorker";

export function sortFiles(files: EnteFile[], sortAsc = false) {
    // sort based on the time of creation time of the file,
    // for files with same creation time, sort based on the time of last modification
    const factor = sortAsc ? -1 : 1;
    return files.sort((a, b) => {
        if (a.metadata.creationTime === b.metadata.creationTime) {
            return (
                factor *
                (b.metadata.modificationTime - a.metadata.modificationTime)
            );
        }
        return factor * (b.metadata.creationTime - a.metadata.creationTime);
    });
}

export async function decryptFile(
    file: EncryptedEnteFile,
    collectionKey: string,
): Promise<EnteFile> {
    try {
        const worker = await ComlinkCryptoWorker.getInstance();
        const {
            encryptedKey,
            keyDecryptionNonce,
            metadata,
            magicMetadata,
            pubMagicMetadata,
            ...restFileProps
        } = file;
        const fileKey = await worker.decryptB64(
            encryptedKey,
            keyDecryptionNonce,
            collectionKey,
        );
        const fileMetadata = await worker.decryptMetadata(
            metadata.encryptedData,
            metadata.decryptionHeader,
            fileKey,
        );
        let fileMagicMetadata: FileMagicMetadata;
        let filePubMagicMetadata: FilePublicMagicMetadata;
        if (magicMetadata?.data) {
            fileMagicMetadata = {
                ...file.magicMetadata,
                data: await worker.decryptMetadata(
                    magicMetadata.data,
                    magicMetadata.header,
                    fileKey,
                ),
            };
        }
        if (pubMagicMetadata?.data) {
            filePubMagicMetadata = {
                ...pubMagicMetadata,
                data: await worker.decryptMetadata(
                    pubMagicMetadata.data,
                    pubMagicMetadata.header,
                    fileKey,
                ),
            };
        }
        return {
            ...restFileProps,
            key: fileKey,
            metadata: fileMetadata,
            magicMetadata: fileMagicMetadata,
            pubMagicMetadata: filePubMagicMetadata,
        };
    } catch (e) {
        logError(e, "file decryption failed");
        throw e;
    }
}

export function getFileNameWithoutExtension(filename: string) {
    const lastDotPosition = filename.lastIndexOf(".");
    if (lastDotPosition === -1) return filename;
    else return filename.slice(0, lastDotPosition);
}

export function getFileExtensionWithDot(filename: string) {
    const lastDotPosition = filename.lastIndexOf(".");
    if (lastDotPosition === -1) return "";
    else return filename.slice(lastDotPosition);
}

export function splitFilenameAndExtension(filename: string): [string, string] {
    const lastDotPosition = filename.lastIndexOf(".");
    if (lastDotPosition === -1) return [filename, null];
    else
        return [
            filename.slice(0, lastDotPosition),
            filename.slice(lastDotPosition + 1),
        ];
}

export function getFileExtension(filename: string) {
    return splitFilenameAndExtension(filename)[1]?.toLocaleLowerCase();
}

export function generateStreamFromArrayBuffer(data: Uint8Array) {
    return new ReadableStream({
        async start(controller: ReadableStreamDefaultController) {
            controller.enqueue(data);
            controller.close();
        },
    });
}

export async function getRenderableFileURL(file: EnteFile, fileBlob: Blob) {
    switch (file.metadata.fileType) {
        case FILE_TYPE.IMAGE: {
            const convertedBlob = await getRenderableImage(
                file.metadata.title,
                fileBlob,
            );
            const { originalURL, convertedURL } = getFileObjectURLs(
                fileBlob,
                convertedBlob,
            );
            return {
                converted: [convertedURL],
                original: [originalURL],
            };
        }
        case FILE_TYPE.LIVE_PHOTO: {
            return await getRenderableLivePhotoURL(file, fileBlob);
        }
        case FILE_TYPE.VIDEO: {
            const convertedBlob = await getPlayableVideo(
                file.metadata.title,
                fileBlob,
            );
            const { originalURL, convertedURL } = getFileObjectURLs(
                fileBlob,
                convertedBlob,
            );
            return {
                converted: [convertedURL],
                original: [originalURL],
            };
        }
        default: {
            const previewURL = await createTypedObjectURL(
                fileBlob,
                file.metadata.title,
            );
            return {
                converted: [previewURL],
                original: [previewURL],
            };
        }
    }
}

async function getRenderableLivePhotoURL(
    file: EnteFile,
    fileBlob: Blob,
): Promise<{ original: string[]; converted: string[] }> {
    const livePhoto = await decodeLivePhoto(file, fileBlob);
    const imageBlob = new Blob([livePhoto.image]);
    const videoBlob = new Blob([livePhoto.video]);
    const convertedImageBlob = await getRenderableImage(
        livePhoto.imageNameTitle,
        imageBlob,
    );
    const convertedVideoBlob = await getPlayableVideo(
        livePhoto.videoNameTitle,
        videoBlob,
        true,
    );
    const { originalURL: originalImageURL, convertedURL: convertedImageURL } =
        getFileObjectURLs(imageBlob, convertedImageBlob);

    const { originalURL: originalVideoURL, convertedURL: convertedVideoURL } =
        getFileObjectURLs(videoBlob, convertedVideoBlob);
    return {
        converted: [convertedImageURL, convertedVideoURL],
        original: [originalImageURL, originalVideoURL],
    };
}

export async function getPlayableVideo(
    videoNameTitle: string,
    videoBlob: Blob,
    forceConvert = false,
) {
    try {
        const isPlayable = await isPlaybackPossible(
            URL.createObjectURL(videoBlob),
        );
        if (isPlayable && !forceConvert) {
            return videoBlob;
        } else {
            if (!forceConvert) {
                return null;
            }
            addLogLine(
                "video format not supported, converting it name:",
                videoNameTitle,
            );
            const mp4ConvertedVideo = await ffmpegService.convertToMP4(
                new File([videoBlob], videoNameTitle),
            );
            addLogLine("video successfully converted", videoNameTitle);
            return new Blob([await mp4ConvertedVideo.arrayBuffer()]);
        }
    } catch (e) {
        addLogLine("video conversion failed", videoNameTitle);
        logError(e, "video conversion failed");
        return null;
    }
}

export async function getRenderableImage(fileName: string, imageBlob: Blob) {
    let fileTypeInfo: FileTypeInfo;
    try {
        const tempFile = new File([imageBlob], fileName);
        fileTypeInfo = await getFileType(tempFile);
        addLocalLog(() => `file type info: ${JSON.stringify(fileTypeInfo)}`);
        const { exactType } = fileTypeInfo;
        let convertedImageBlob: Blob;
        if (isRawFile(exactType)) {
            try {
                if (!isSupportedRawFormat(exactType)) {
                    throw Error(CustomError.UNSUPPORTED_RAW_FORMAT);
                }

                throw Error(CustomError.NOT_AVAILABLE_ON_WEB);
            } catch (e) {
                try {
                    if (!isFileHEIC(exactType)) {
                        throw e;
                    }
                    addLogLine(
                        `HEICConverter called for ${fileName}-${convertBytesToHumanReadable(
                            imageBlob.size,
                        )}`,
                    );
                    convertedImageBlob =
                        await heicConversionService.convert(imageBlob);
                    addLogLine(`${fileName} successfully converted`);
                } catch (e) {
                    throw Error(CustomError.NON_PREVIEWABLE_FILE);
                }
            }
            return convertedImageBlob;
        } else {
            return imageBlob;
        }
    } catch (e) {
        logError(e, "get Renderable Image failed", { fileTypeInfo });
        return null;
    }
}

export function isFileHEIC(exactType: string) {
    return (
        exactType.toLowerCase().endsWith(TYPE_HEIC) ||
        exactType.toLowerCase().endsWith(TYPE_HEIF)
    );
}

export function isRawFile(exactType: string) {
    return RAW_FORMATS.includes(exactType.toLowerCase());
}

export function isRawFileFromFileName(fileName: string) {
    for (const rawFormat of RAW_FORMATS) {
        if (fileName.toLowerCase().endsWith(rawFormat)) {
            return true;
        }
    }
    return false;
}

export function isSupportedRawFormat(exactType: string) {
    return SUPPORTED_RAW_FORMATS.includes(exactType.toLowerCase());
}

export function mergeMetadata(files: EnteFile[]): EnteFile[] {
    return files.map((file) => {
        if (file.pubMagicMetadata?.data.editedTime) {
            file.metadata.creationTime = file.pubMagicMetadata.data.editedTime;
        }
        if (file.pubMagicMetadata?.data.editedName) {
            file.metadata.title = file.pubMagicMetadata.data.editedName;
        }

        return file;
    });
}

export async function getFileFromURL(fileURL: string) {
    const fileBlob = await (await fetch(fileURL)).blob();
    const fileFile = new File([fileBlob], "temp");
    return fileFile;
}

export function getUniqueFiles(files: EnteFile[]) {
    const idSet = new Set<number>();
    const uniqueFiles = files.filter((file) => {
        if (!idSet.has(file.id)) {
            idSet.add(file.id);
            return true;
        } else {
            return false;
        }
    });

    return uniqueFiles;
}

export const isImageOrVideo = (fileType: FILE_TYPE) =>
    [FILE_TYPE.IMAGE, FILE_TYPE.VIDEO].includes(fileType);

export const createTypedObjectURL = async (blob: Blob, fileName: string) => {
    const type = await getFileType(new File([blob], fileName));
    return URL.createObjectURL(new Blob([blob], { type: type.mimeType }));
};

export const getUserOwnedFiles = (files: EnteFile[]) => {
    const user: User = getData(LS_KEYS.USER);
    if (!user?.id) {
        throw Error("user missing");
    }
    return files.filter((file) => file.ownerID === user.id);
};

export const getPreviewableImage = async (
    file: EnteFile,
    castToken: string,
): Promise<Blob> => {
    try {
        let fileBlob = await new Response(
            await CastDownloadManager.downloadFile(castToken, file),
        ).blob();
        if (file.metadata.fileType === FILE_TYPE.LIVE_PHOTO) {
            const livePhoto = await decodeLivePhoto(file, fileBlob);
            fileBlob = new Blob([livePhoto.image]);
        }
        const fileType = await getFileType(
            new File([fileBlob], file.metadata.title),
        );
        fileBlob = new Blob([fileBlob], { type: fileType.mimeType });
        return fileBlob;
    } catch (e) {
        logError(e, "failed to download file");
    }
};

const getFileObjectURLs = (originalBlob: Blob, convertedBlob: Blob) => {
    const originalURL = URL.createObjectURL(originalBlob);
    const convertedURL = convertedBlob
        ? convertedBlob === originalBlob
            ? originalURL
            : URL.createObjectURL(convertedBlob)
        : null;
    return { originalURL, convertedURL };
};
