/**
 * Will take the active revision of the specified Cloud Run service and check if the GTM image sha 
 * is the same as the latest stable version of the GTM image. 
 * In case of mismatch a new revision will be created copying the variables and resources from the last active revision.
 * 
 * @param req Post request keys required: project_id, region, service_name
 * @returns The status of the currently deployed Cloud Run service
 */

const functions = require('@google-cloud/functions-framework');
const {RevisionsClient,ServicesClient} = require('@google-cloud/run').v2;

const fetch = require('node-fetch')

const runClient = new RevisionsClient();
const service_client = new ServicesClient();

functions.http('check_cloud_run', (req, res) => {

  if(req.body.project_id && req.body.region && req.body.service_name){
    let params = {
        ...req.body
    }
    console.log(params)
    check_cloud_run(params);
  }
  else{
    res.status(500).json({"success":"false","message":"Wrong / Missing request body"});
  }

  async function check_cloud_run(params) {

    const parent = `projects/${params.project_id}/locations/${params.region}/services/${params.service_name}`
    const request = {
        parent,
    };
    
    let revisions_list = [];
    let active_revision;

    const iterable = await runClient.listRevisionsAsync(request);
    for await (const response of iterable) {
        revisions_list.push(response)
    }

    for (const revision of revisions_list) {
        for (const condition of revision.conditions) {
            if(condition.type == "Active" && condition.state == "CONDITION_SUCCEEDED") {
                active_revision = revision;
            }
        }
    }
    let current_image_key = active_revision.containers[0].image.split(":")[1];
    
    console.log(`Currently deployed GTM image version sha: ${current_image_key}`);
  
    const url = 'https://gcr.io/v2/cloud-tagging-10302018/gtm-cloud-image/tags/list';

    const response = await fetch(url, {
      method: 'GET',
    });

    if (!response.ok) {
      throw new Error(`HTTP error! Status: ${response.status}`);
    }
    
    let image_manifest = await response.json();
    image_manifest = image_manifest.manifest;

    let stable_image_key = null;
    let stable_image_tags = null;
    for (const release in image_manifest) {
        if (Array.isArray(image_manifest[release].tag) && image_manifest[release].tag.includes('stable')) {
            stable_image_key = release.split(":")[1];
            stable_image_tags = image_manifest[release].tag;
            break; 
        }
    }

    console.log(`Stable GTM image sha: ${stable_image_key} and tags ${stable_image_tags}`);

    if(stable_image_key != current_image_key) {
        console.log(`Versions are different: Deploying a new revision to catch latest stable image: ${stable_image_key}`);
        console.log(active_revision);
        const service = {
            "name": `projects/${params.project_id}/locations/${params.region}/services/${params.service_name}`,
            "template":{
                "containers":[
                    {
                        "image": "gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable",
                        "env": active_revision.containers[0].env,
                        "resources": active_revision.containers[0].resources,
                        "livenessProbe": active_revision.containers[0].livenessProbe,
                        "startupProbe": active_revision.containers[0].startupProbe,
                    }
                ],
                scaling:{
                    "minInstanceCount":active_revision.scaling.minInstanceCount,
                    "maxInstanceCount":active_revision.scaling.maxInstanceCount
                },
                "serviceAccount": active_revision.serviceAccount
            }
        }

        const revision_request = {
            service,
        };
  
        const [operation] = await service_client.updateService(revision_request);
        const [revision_response] = await operation.promise();
        console.log(revision_response);

        return res.status(200).json({
            "status":"updated successfully",
            "gtm-version": current_image_key,
            "latest-image-version": stable_image_key
        });
    }   
   
    return res.status(200).json({
        "status":"no update needed",
        "gtm-version": current_image_key,
        "latest-image-version": stable_image_key
    });
  }
});