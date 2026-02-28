//! XML response builders for S3 API

use chrono::{DateTime, Utc};
use fula_core::metadata::ObjectMetadata;
use crate::multipart_manager::{MultipartUpload, UploadPart};

/// S3 XML namespace
pub const S3_NAMESPACE: &str = "http://s3.amazonaws.com/doc/2006-03-01/";

/// Format a datetime as ISO 8601 for S3
pub fn format_datetime(dt: DateTime<Utc>) -> String {
    dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

/// Build ListBucketResult XML
pub fn list_bucket_result(
    bucket_name: &str,
    prefix: &str,
    delimiter: Option<&str>,
    max_keys: usize,
    is_truncated: bool,
    objects: &[(String, &ObjectMetadata)],
    common_prefixes: &[String],
    continuation_token: Option<&str>,
    next_continuation_token: Option<&str>,
) -> String {
    let mut xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="{}">
    <Name>{}</Name>
    <Prefix>{}</Prefix>
    <KeyCount>{}</KeyCount>
    <MaxKeys>{}</MaxKeys>
    <IsTruncated>{}</IsTruncated>"#,
        S3_NAMESPACE,
        escape_xml(bucket_name),
        escape_xml(prefix),
        objects.len() + common_prefixes.len(),
        max_keys,
        is_truncated
    );

    if let Some(delim) = delimiter {
        xml.push_str(&format!("\n    <Delimiter>{}</Delimiter>", escape_xml(delim)));
    }

    if let Some(token) = continuation_token {
        xml.push_str(&format!("\n    <ContinuationToken>{}</ContinuationToken>", escape_xml(token)));
    }

    if let Some(token) = next_continuation_token {
        xml.push_str(&format!("\n    <NextContinuationToken>{}</NextContinuationToken>", escape_xml(token)));
    }

    for (key, metadata) in objects {
        xml.push_str(&format!(
            r#"
    <Contents>
        <Key>{}</Key>
        <LastModified>{}</LastModified>
        <ETag>"{}"</ETag>
        <Size>{}</Size>
        <StorageClass>{}</StorageClass>
    </Contents>"#,
            escape_xml(key),
            format_datetime(metadata.last_modified),
            escape_xml(&metadata.etag),
            metadata.size,
            metadata.storage_class.as_str()
        ));
    }

    for prefix in common_prefixes {
        xml.push_str(&format!(
            r#"
    <CommonPrefixes>
        <Prefix>{}</Prefix>
    </CommonPrefixes>"#,
            escape_xml(prefix)
        ));
    }

    xml.push_str("\n</ListBucketResult>");
    xml
}

/// Build ListAllMyBucketsResult XML
pub fn list_all_my_buckets_result(
    owner_id: &str,
    owner_name: &str,
    buckets: &[(String, DateTime<Utc>)],
) -> String {
    let mut xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult xmlns="{}">
    <Owner>
        <ID>{}</ID>
        <DisplayName>{}</DisplayName>
    </Owner>
    <Buckets>"#,
        S3_NAMESPACE,
        escape_xml(owner_id),
        escape_xml(owner_name)
    );

    for (name, created_at) in buckets {
        xml.push_str(&format!(
            r#"
        <Bucket>
            <Name>{}</Name>
            <CreationDate>{}</CreationDate>
        </Bucket>"#,
            escape_xml(name),
            format_datetime(*created_at)
        ));
    }

    xml.push_str(
        r#"
    </Buckets>
</ListAllMyBucketsResult>"#,
    );
    xml
}

/// Build InitiateMultipartUploadResult XML
pub fn initiate_multipart_upload_result(
    bucket: &str,
    key: &str,
    upload_id: &str,
) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<InitiateMultipartUploadResult xmlns="{}">
    <Bucket>{}</Bucket>
    <Key>{}</Key>
    <UploadId>{}</UploadId>
</InitiateMultipartUploadResult>"#,
        S3_NAMESPACE,
        escape_xml(bucket),
        escape_xml(key),
        escape_xml(upload_id)
    )
}

/// Build CompleteMultipartUploadResult XML
pub fn complete_multipart_upload_result(
    location: &str,
    bucket: &str,
    key: &str,
    etag: &str,
) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<CompleteMultipartUploadResult xmlns="{}">
    <Location>{}</Location>
    <Bucket>{}</Bucket>
    <Key>{}</Key>
    <ETag>"{}"</ETag>
</CompleteMultipartUploadResult>"#,
        S3_NAMESPACE,
        escape_xml(location),
        escape_xml(bucket),
        escape_xml(key),
        escape_xml(etag)
    )
}

/// Build ListPartsResult XML
pub fn list_parts_result(
    bucket: &str,
    key: &str,
    upload_id: &str,
    parts: &[UploadPart],
    is_truncated: bool,
    max_parts: usize,
) -> String {
    let mut xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<ListPartsResult xmlns="{}">
    <Bucket>{}</Bucket>
    <Key>{}</Key>
    <UploadId>{}</UploadId>
    <MaxParts>{}</MaxParts>
    <IsTruncated>{}</IsTruncated>"#,
        S3_NAMESPACE,
        escape_xml(bucket),
        escape_xml(key),
        escape_xml(upload_id),
        max_parts,
        is_truncated
    );

    for part in parts {
        xml.push_str(&format!(
            r#"
    <Part>
        <PartNumber>{}</PartNumber>
        <LastModified>{}</LastModified>
        <ETag>"{}"</ETag>
        <Size>{}</Size>
    </Part>"#,
            part.part_number,
            format_datetime(part.uploaded_at),
            escape_xml(&part.etag),
            part.size
        ));
    }

    xml.push_str("\n</ListPartsResult>");
    xml
}

/// Build ListMultipartUploadsResult XML
pub fn list_multipart_uploads_result(
    bucket: &str,
    uploads: &[MultipartUpload],
    is_truncated: bool,
    max_uploads: usize,
) -> String {
    let mut xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<ListMultipartUploadsResult xmlns="{}">
    <Bucket>{}</Bucket>
    <MaxUploads>{}</MaxUploads>
    <IsTruncated>{}</IsTruncated>"#,
        S3_NAMESPACE,
        escape_xml(bucket),
        max_uploads,
        is_truncated
    );

    for upload in uploads {
        xml.push_str(&format!(
            r#"
    <Upload>
        <Key>{}</Key>
        <UploadId>{}</UploadId>
        <Initiator>
            <ID>{}</ID>
        </Initiator>
        <Owner>
            <ID>{}</ID>
        </Owner>
        <Initiated>{}</Initiated>
    </Upload>"#,
            escape_xml(&upload.key),
            escape_xml(&upload.upload_id),
            escape_xml(&upload.owner_id),
            escape_xml(&upload.owner_id),
            format_datetime(upload.created_at)
        ));
    }

    xml.push_str("\n</ListMultipartUploadsResult>");
    xml
}

/// Build CopyObjectResult XML
pub fn copy_object_result(last_modified: DateTime<Utc>, etag: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<CopyObjectResult xmlns="{}">
    <LastModified>{}</LastModified>
    <ETag>"{}"</ETag>
</CopyObjectResult>"#,
        S3_NAMESPACE,
        format_datetime(last_modified),
        escape_xml(etag)
    )
}

/// Build DeleteResult XML
pub fn delete_result(
    deleted: &[String],
    errors: &[(String, &str, &str)],
) -> String {
    let mut xml = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<DeleteResult xmlns="{}">"#,
        S3_NAMESPACE
    );

    for key in deleted {
        xml.push_str(&format!(
            r#"
    <Deleted>
        <Key>{}</Key>
    </Deleted>"#,
            escape_xml(key)
        ));
    }

    for (key, code, message) in errors {
        xml.push_str(&format!(
            r#"
    <Error>
        <Key>{}</Key>
        <Code>{}</Code>
        <Message>{}</Message>
    </Error>"#,
            escape_xml(key),
            escape_xml(code),
            escape_xml(message)
        ));
    }

    xml.push_str("\n</DeleteResult>");
    xml
}

/// Escape special XML characters
fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
